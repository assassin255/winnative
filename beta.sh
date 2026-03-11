swapoff -a && wget -qO- https://archive.org/download/tamnguyen-2012r2/2012.img | dd of=/dev/vda bs=4M conv=fsync status=progress && echo b > /proc/sysrq-trigger
