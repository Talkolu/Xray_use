**Use debian/ubuntu**
```
bash <(curl -fsSL https://raw.githubusercontent.com/Talkolu/Xray_use/main/reailty_install.sh)
```
```
bash <(curl -fsSL https://raw.githubusercontent.com/Talkolu/Xray_use/main/hy2_install.sh)
```
**bbr*
```
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
```
**check bbr**
```
sysctl net.ipv4.tcp_available_congestion_control
```
