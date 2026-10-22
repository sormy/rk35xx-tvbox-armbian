# First login

The first login, over `ssh` or on `tty1`, asks for a new root password; the image ships `1234`,
expired. Nothing else runs. The rest is yours to set, as root on the box:

```bash
adduser <user> && adduser <user> sudo                          # an everyday user
for g in video render audio input; do adduser <user> $g; done  # …with the codecs, sound, remote
timedatectl list-timezones | grep -i <city>                    # find yours, then:
timedatectl set-timezone <Region/City>
echo "<locale> UTF-8" >>/etc/locale.gen && locale-gen && update-locale LANG=<locale>   # de_DE.UTF-8
nmtui                                                          # Wi-Fi, or:
nmcli --ask device wifi connect "<SSID>"
hostnamectl hostname <name>                                    # the box answers <name>.local
```

The locale takes effect from the next login.
