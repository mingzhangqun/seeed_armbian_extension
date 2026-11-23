# A/B env repair key spec — the single source for the runtime repair loop
# (ab/env.sh) and the build-time completeness check (uboot-default-env.sh,
# which sources this from the repo tree). Every key must carry a value in
# the merged /etc/u-boot-initial-env or repair fails on every boot.
# missing: fill only when absent; sync: force to the initial-env value.

AB_ENV_MISSING_KEYS="ota_in_progress slot_retry_max slot_retry_left"
AB_ENV_SYNC_KEYS="ab_preboot ab_select_boot_part scan_dev_for_boot_part ab_select_fit_slot bootcmd"
