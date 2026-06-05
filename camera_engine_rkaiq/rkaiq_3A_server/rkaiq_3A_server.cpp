#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h> /* getopt_long() */
#include <fcntl.h> /* low-level i/o */
#include <inttypes.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <pthread.h>

#include <linux/videodev2.h>
#include <signal.h>
#include <setjmp.h>
#include "uAPI2/rk_aiq_user_api2_sysctl.h"
#include "common/mediactl/mediactl.h"
#include "common/mediactl/mediactl-priv.h"

static sigjmp_buf jump_buf;
static volatile sig_atomic_t jump_active = 0;

static void sigsegv_handler(int sig)
{
    if (jump_active)
        siglongjmp(jump_buf, 1);
    _exit(128 + sig);
}

#define CLEAR(x) memset(&(x), 0, sizeof(x))
#define DBG(...) do { if(!silent) printf("DBG: " __VA_ARGS__);} while(0)
#define ERR(...) do { fprintf(stderr, "ERR: " __VA_ARGS__); } while (0)

/* --- Exposure forwarding for RK3576 virtual ISP --- */
static int g_real_sensor_fd = -1;

static int open_real_sensor_subdev(const char *sensor_entity_name) {
    if (!sensor_entity_name || strlen(sensor_entity_name) == 0)
        return -1;
    for (int mi = 0; mi < 16; mi++) {
        char mpath[32];
        snprintf(mpath, sizeof(mpath), "/dev/media%d", mi);
        struct media_device *mdev = media_device_new(mpath);
        if (!mdev) continue;
        if (media_device_enumerate(mdev) < 0) { media_device_unref(mdev); continue; }
        for (unsigned int ei = 0; ei < media_get_entities_count(mdev); ei++) {
            struct media_entity *ent = media_get_entity(mdev, ei);
            const char *ename = media_entity_get_info(ent)->name;
            if (ename && strstr(ename, sensor_entity_name)) {
                const char *devname = media_entity_get_devname(ent);
                if (devname) {
                    int fd = open(devname, O_RDWR);
                    if (fd >= 0) {
                        printf("DBG: Opened real sensor '%s' via %s (fd=%d)\n", ename, devname, fd);
                        media_device_unref(mdev);
                        return fd;
                    }
                }
            }
        }
        media_device_unref(mdev);
    }
    fprintf(stderr, "ERR: Could not find real sensor for '%s'\n", sensor_entity_name);
    return -1;
}

static void set_sensor_exposure(int fd, uint32_t exp, uint32_t gain) {
    struct v4l2_control ctrl;
    ctrl.id = V4L2_CID_EXPOSURE; ctrl.value = exp;
    ioctl(fd, VIDIOC_S_CTRL, &ctrl);
    ctrl.id = V4L2_CID_ANALOGUE_GAIN; ctrl.value = gain;
    ioctl(fd, VIDIOC_S_CTRL, &ctrl);
}

/* Private v4l2 event */
#define CIFISP_V4L2_EVENT_STREAM_START  \
                    (V4L2_EVENT_PRIVATE_START + 1)
#define CIFISP_V4L2_EVENT_STREAM_STOP   \
                    (V4L2_EVENT_PRIVATE_START + 2)

#define RKAIQ_FILE_PATH_LEN                       64
#define RKAIQ_FLASH_NUM_MAX                       2

/* 1 vicap + 2 mipi + 1 bridge + 1 redundance */
#define MAX_MEDIA_NODES                           16

#define IQ_PATH "/etc/iqfiles/"

static int silent = 0;
static int width = 2688;
static int height = 1520;
static int has_mul_cam = 0;

struct rkaiq_media_info {
    char sd_isp_path[RKAIQ_FILE_PATH_LEN];
    char vd_params_path[RKAIQ_FILE_PATH_LEN];
    char vd_stats_path[RKAIQ_FILE_PATH_LEN];
    char mainpath[RKAIQ_FILE_PATH_LEN];
    char sensor_entity_name[32];

    char mdev_path[32];
    int available;
    rk_aiq_sys_ctx_t* aiq_ctx;

    pthread_t pid;
};

static struct rkaiq_media_info media_infos[MAX_MEDIA_NODES];
static void errno_exit(const char *s)
{
    ERR("%s error %d, %s\n", s, errno, strerror(errno));
    exit(EXIT_FAILURE);
}

static int xioctl(int fh, int request, void *arg)
{
    int r;

    do {
        r = ioctl(fh, request, arg);
    } while (-1 == r && EINTR == errno);

    return r;
}


static int rkaiq_get_devname(struct media_device *device, const char *name, char *dev_name)
{
    const char *devname;
    struct media_entity *entity =  NULL;

    entity = media_get_entity_by_name(device, name, strlen(name));
    if (!entity)
        return -1;

    devname = media_entity_get_devname(entity);

    if (!devname) {
        fprintf(stderr, "can't find %s device path!", name);
        return -1;
    }

    strncpy(dev_name, devname, RKAIQ_FILE_PATH_LEN);

    DBG("get %s devname: %s\n", name, dev_name);

    return 0;
}

int rkaiq_get_media_info(struct rkaiq_media_info *media_info)
{
    struct media_device *device = NULL;
    const char *sensor_name;
    int ret;

    device = media_device_new (media_info->mdev_path);
    if (!device)
        return -ENOMEM;
    /* Enumerate entities, pads and links. */
    ret = media_device_enumerate (device);
    if (ret)
        return ret;
    if (!ret) {
        /* Try rkisp */
        ret = rkaiq_get_devname(device, "rkisp-isp-subdev",
                                media_info->sd_isp_path);
        ret |= rkaiq_get_devname(device, "rkisp-input-params",
                                media_info->vd_params_path);
        ret |= rkaiq_get_devname(device, "rkisp-statistics",
                                media_info->vd_stats_path);
        ret |= rkaiq_get_devname(device, "rkisp_mainpath",
                                media_info->mainpath);
    }
    if (ret) {
        fprintf(stderr, "Cound not find rkisp dev names, skipped %s\n", media_info->mdev_path);
        media_device_unref (device);
        return ret;
    }

    sensor_name = rk_aiq_uapi2_sysctl_getBindedSnsEntNmByVd(media_info->mainpath);
    if (sensor_name == NULL || strlen(sensor_name) == 0) {
        fprintf(stderr, "ERR: No sensor attached to %s\n", media_info->mdev_path);
        media_device_unref (device);
        return -EINVAL;
    }

    if (strncmp(sensor_name, "FakeCamera", 10) == 0) {
        /* Check if this ISP has a CIF link (real camera connected).
         * ISPs without CIF links have no camera and should be skipped.
         */
        bool has_cif_link = false;
        for (unsigned int ei = 0; ei < media_get_entities_count(device); ei++) {
            media_entity *ent = media_get_entity(device, ei);
            const char *ename = media_entity_get_info(ent)->name;
            if (ename && strncmp(ename, "rkcif", 5) == 0)
                has_cif_link = true;
        }
        if (!has_cif_link) {
            DBG("No CIF link on %s, skipping FakeCamera\n", media_info->mdev_path);
            media_device_unref(device);
            return -EINVAL;
        }

        /* Find real sensor name from CIF media devices */
        const char *real_name = NULL;
        for (int mi = 0; mi < MAX_MEDIA_NODES && !real_name; mi++) {
            char mpath[32];
            struct media_device *cif_dev;
            sprintf(mpath, "/dev/media%d", mi);
            cif_dev = media_device_new(mpath);
            if (!cif_dev)
                continue;
            if (media_device_enumerate(cif_dev) < 0) {
                media_device_unref(cif_dev);
                continue;
            }
            for (unsigned int ei = 0; ei < media_get_entities_count(cif_dev); ei++) {
                media_entity *ent = media_get_entity(cif_dev, ei);
                const char *ename = media_entity_get_info(ent)->name;
                if (ename && ename[0] == 'm' && strchr(ename, ' ') && strstr(ename, "_f_"))
                    real_name = ename;
            }
            media_device_unref(cif_dev);
        }
        if (real_name) {
            DBG("Resolved fake sensor '%s' to '%s'\n", sensor_name, real_name);
            sensor_name = real_name;
        } else {
            ERR("Cannot resolve fake sensor '%s' on %s\n", sensor_name, media_info->mdev_path);
            media_device_unref(device);
            return -EINVAL;
        }
    }

    strcpy(media_info->sensor_entity_name, sensor_name);

    media_device_unref (device);

    return ret;
}

static int init_engine(struct rkaiq_media_info *media_info)
{
    media_info->aiq_ctx = rk_aiq_uapi2_sysctl_init(media_info->sensor_entity_name,
                                                  IQ_PATH, NULL, NULL);
    if (!media_info->aiq_ctx) {
        ERR("rk_aiq_uapi2_sysctl_init failed for %s\n", media_info->sensor_entity_name);
        return -1;
    }
    /* 3A server has listened stream events already */
    rk_aiq_uapi2_sysctl_setListenStrmStatus(media_info->aiq_ctx, false);
    if (has_mul_cam)
        rk_aiq_uapi2_sysctl_setMulCamConc(media_info->aiq_ctx, 1);

    if (rk_aiq_uapi2_sysctl_prepare(media_info->aiq_ctx,
            width, height, RK_AIQ_WORKING_MODE_NORMAL)) {
        ERR("rkaiq engine prepare failed for %s!\n", media_info->sensor_entity_name);
        return -1;
    }
    return 0;
}

static void start_engine(struct rkaiq_media_info *media_info)
{
    DBG("device manager start\n");
    rk_aiq_uapi2_sysctl_start(media_info->aiq_ctx);
    if (media_info->aiq_ctx == NULL) {
        ERR("rkisp_init engine failed\n");
        exit(-1);
    } else {
        DBG("rkisp_init engine succeed\n");
    }
}

static void stop_engine(struct rkaiq_media_info *media_info)
{
    rk_aiq_uapi2_sysctl_stop(media_info->aiq_ctx, false);
}

static void deinit_engine(struct rkaiq_media_info *media_info)
{
    rk_aiq_uapi2_sysctl_deinit(media_info->aiq_ctx);
}

// blocked func
static int wait_stream_event(int fd, unsigned int event_type, int time_out_ms)
{
    int ret;
    struct v4l2_event event;

    CLEAR(event);

    do {
        /*
         * xioctl instead of poll.
         * Since poll() cannot wait for input before stream on,
         * it will return an error directly. So, use ioctl to
         * dequeue event and block until sucess.
         */
        ret = xioctl(fd, VIDIOC_DQEVENT, &event);
        if (ret == 0 && event.type == event_type)
            return 0;
    } while (true);

    return -1;

}

static int subscrible_stream_event(struct rkaiq_media_info *media_info, int fd, bool subs)
{
    struct v4l2_event_subscription sub;
    int ret = 0;

    CLEAR(sub);
    sub.type = CIFISP_V4L2_EVENT_STREAM_START;
    ret = xioctl(fd,
                 subs ? VIDIOC_SUBSCRIBE_EVENT : VIDIOC_UNSUBSCRIBE_EVENT,
                 &sub);
    if (ret) {
        ERR("can't subscribe %s start event!\n", media_info->vd_params_path);
        exit(EXIT_FAILURE);
    }

    CLEAR(sub);
    sub.type = CIFISP_V4L2_EVENT_STREAM_STOP;
    ret = xioctl(fd,
                 subs ? VIDIOC_SUBSCRIBE_EVENT : VIDIOC_UNSUBSCRIBE_EVENT,
                 &sub);
    if (ret) {
        ERR("can't subscribe %s stop event!\n", media_info->vd_params_path);
    }

    DBG("subscribe events from %s success !\n", media_info->vd_params_path);

    return 0;
}

void parse_args(int argc, char **argv)
{
   int c;
   int digit_optind = 0;

   while (1) {
       int this_option_optind = optind ? optind : 1;
       int option_index = 0;
       static struct option long_options[] = {
           {"silent",    no_argument,       0, 's' },
           {"help",      no_argument,       0, 'h' },
           {0,           0,                 0,  0  }
       };

       c = getopt_long(argc, argv, "sh", long_options, &option_index);
       if (c == -1)
           break;

       switch (c) {
       case 'w':
           width = atoi(optarg);
           break;
       case 'h':
           height = atoi(optarg);
           break;
       case 's':
           silent = 1;
           break;
       case '?':
           ERR("Usage: %s to start 3A engine\n"
               "         --silent,  optional, subpress debug log\n",
               argv[0]);
           exit(-1);

       default:
           ERR("?? getopt returned character code %c ??\n", c);
       }
   }
}

void *engine_thread(void *arg)
{
    int ret = 0;
    int isp_fd;
    unsigned int stream_event = -1;
    struct rkaiq_media_info *media_info;

    media_info = (struct rkaiq_media_info *) arg;

    isp_fd = open(media_info->vd_params_path, O_RDWR);
    if (isp_fd < 0) {
        ERR("open %s failed %s\n", media_info->vd_params_path, strerror(errno));
        return NULL;
    }

    struct sigaction sa, old_sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigsegv_handler;
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGSEGV, &sa, &old_sa);

    jump_active = 1;
    if (sigsetjmp(jump_buf, 1)) {
        ERR("Caught SIGSEGV in engine_thread for %s, skipping\n", media_info->mdev_path);
        jump_active = 0;
        sigaction(SIGSEGV, &old_sa, NULL);
        close(isp_fd);
        media_info->available = 0;
        return NULL;
    }

    if (init_engine(media_info) != 0) {
        ERR("init_engine failed for %s, skipping\n", media_info->mdev_path);
        jump_active = 0;
        sigaction(SIGSEGV, &old_sa, NULL);
        close(isp_fd);
        media_info->available = 0;
        return NULL;
    }

    jump_active = 0;
    sigaction(SIGSEGV, &old_sa, NULL);

    /* Open real sensor for exposure forwarding */
    g_real_sensor_fd = open_real_sensor_subdev(media_info->sensor_entity_name);

    subscrible_stream_event(media_info, isp_fd, true);

    for (;;) {
        DBG("%s: wait stream start event...\n", media_info->mdev_path);
        wait_stream_event(isp_fd, CIFISP_V4L2_EVENT_STREAM_START, -1);
        DBG("%s: wait stream start event success ...\n", media_info->mdev_path);
        start_engine(media_info);

        /* Forward exposure to real sensor */
        if (g_real_sensor_fd >= 0) {
            set_sensor_exposure(g_real_sensor_fd, 2000, 8000);
            DBG("Set sensor exposure: exp=2000 gain=8000\n");
        }

        DBG("%s: wait stream stop event...\n", media_info->mdev_path);
        wait_stream_event(isp_fd, CIFISP_V4L2_EVENT_STREAM_STOP, -1);
        DBG("%s: wait stream stop event success ...\n", media_info->mdev_path);

        stop_engine(media_info);
    }

    subscrible_stream_event(media_info, isp_fd, false);
    deinit_engine(media_info);
    close(isp_fd);

    return NULL;
}

int main(int argc, char **argv)
{
    int ret, i;
    int threads = 0;

    /* Line buffered so that printf can flash every line if redirected to
     * no-interactive device.
     */
    setlinebuf(stdout);

    parse_args(argc, argv);

    for (i = 0; i < MAX_MEDIA_NODES; i++) {
        sprintf(media_infos[i].mdev_path, "/dev/media%d", i);
        if (rkaiq_get_media_info(&media_infos[i])) {
            ERR("Bad media topology for: %s\n", media_infos[i].mdev_path);
            media_infos[i].available = 0;
            continue;
        }
        media_infos[i].available = 1;
        threads++;
    }

    if (threads > 1)
        has_mul_cam = 1;

    for (i = 0; i < MAX_MEDIA_NODES; i++) {
        if (!media_infos[i].available)
            continue;
        ret = pthread_create(&media_infos[i].pid, NULL, engine_thread, &media_infos[i]);
        if (ret) {
            media_infos[i].pid = 0;
            ERR("Failed to create camera engine thread for: %s\n", media_infos[i].mdev_path);
            errno_exit("Create thread failed");
        }
    }

    for (i = 0; i < MAX_MEDIA_NODES; i++) {
        if (!media_infos[i].available || media_infos[i].pid == 0)
            continue;
        pthread_join(media_infos[i].pid, NULL);
    }

    return 0;
}
