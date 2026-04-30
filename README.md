# Seeed reComputer APT Repository

This branch is a placeholder. The actual APT repository is deployed to GitHub Pages automatically by CI.

## Usage

```bash
# Add GPG key
curl -fsSL https://seeed-studio.github.io/seeed_armbian_extension/seeed-repo.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/seeed-repo.gpg

# Add source
echo "deb [signed-by=/usr/share/keyrings/seeed-repo.gpg] https://seeed-studio.github.io/seeed_armbian_extension/ stable main" \
    | sudo tee /etc/apt/sources.list.d/seeed.list

# Install packages
sudo apt-get update
sudo apt-get install <package-name>
```

## Packages

| Package | Description |
|---------|-------------|
| `fcs960k-aic-bluez` | FCS960K AIC Bluetooth custom bluez |
| `usbdevice-gadget-rk3588` | USB gadget mode tools |
| `hostapd-morse-tools` | Morse FGH100M hostapd tools |
| `morsectrl-tools` | Morse FGH100M control tools |
| `wpa-supplicant-morse-tools` | Morse FGH100M wpa_supplicant tools |
| `camera-engine-rkaiq-rk3576` | RK3576 camera engine |
| `camera-engine-rkaiq-rk3588` | RK3588 camera engine |
| `libmali-valhall-g610-*` | Mali-G610 GPU userspace driver |
| `realtek-r8125-dkms` | Realtek r8125 NIC DKMS driver |

## CI

Packages are built from source on `deb_sourece` branch via GitHub Actions and deployed to GitHub Pages.
