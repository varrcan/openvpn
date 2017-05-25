#!/bin/bash


if [[ "$USER" != 'root' ]]; then
	echo "К сожалению, скрипт должен быть запущен с правами root"
	exit
fi


if [[ ! -e /dev/net/tun ]]; then
	echo "TUN/TAP недоступен"
	exit
fi


if grep -qs "CentOS release 5" "/etc/redhat-release"; then
	echo "CentOS 5 очень старая версия и не поддерживается"
	exit
fi

if [[ -e /etc/debian_version ]]; then
	OS=debian
	RCLOCAL='/etc/rc.local'
elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
	OS=centos
	RCLOCAL='/etc/rc.d/rc.local'
	# Needed for CentOS 7
	chmod +x /etc/rc.d/rc.local
else
	echo "Похоже, вы не используете эту программу установки в системе Debian, Ubuntu или CentOS"
	exit
fi

newclient () {
	# Generates the custom client.ovpn
	cp /etc/openvpn/client-common.txt ~/$1.ovpn
	echo "<ca>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/ca.crt >> ~/$1.ovpn
	echo "</ca>" >> ~/$1.ovpn
	echo "<cert>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/issued/$1.crt >> ~/$1.ovpn
	echo "</cert>" >> ~/$1.ovpn
	echo "<key>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/private/$1.key >> ~/$1.ovpn
	echo "</key>" >> ~/$1.ovpn
}


# Try to get our IP from the system and fallback to the Internet.
# I do this to make the script compatible with NATed servers (lowendspirit.com)
# and to avoid getting an IPv6.
IP=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -o -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
if [[ "$IP" = "" ]]; then
		IP=$(wget -qO- ipv4.icanhazip.com)
fi


if [[ -e /etc/openvpn/server.conf ]]; then
	while :
	do
	clear
		echo "Похоже, OpenVPN уже установлен"
		echo ""
		echo "Что вы хотите сделать?"
		echo "   1) Добавьте сертификат для нового пользователя"
		echo "   2) Отозвать существующий сертификат"
		echo "   3) Удалить OpenVPN"
		echo "   4) Выйти"
		read -p "Выберите опцию [1-4]: " option
		case $option in
			1)
			echo ""
			echo "Укажите имя пользователя"
			echo "Пожалуйста, используйте только одно слово, без спецсимволов"
			read -p "Имя пользователя: " -e -i client CLIENT
			cd /etc/openvpn/easy-rsa/
			read -p "Длинна ключа (пользователя): " -e -i 4096 KEYSIZE_CLIENT
			read -p "Использовать пароль (пользователя)? " -e -i y USEPASS_CLIENT
			if [ $USEPASS_CLIENT != "y" ]; then
				./easyrsa --keysize=$KEYSIZE_CLIENT build-client-full $CLIENT nopass
			else
				./easyrsa --keysize=$KEYSIZE_CLIENT build-client-full $CLIENT
			fi
			# Generates the custom client.ovpn
			newclient "$CLIENT"
			echo ""
			echo "Пользователь $CLIENT добавлен, сертификаты доступны в ~/$CLIENT.ovpn"
			exit
			;;
			2)
			# This option could be documented a bit better and maybe even be simplimplified
			# ...but what can I say, I want some sleep too
			NUMBEROFCLIENTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c "^V")
			if [[ "$NUMBEROFCLIENTS" = '0' ]]; then
				echo ""
				echo "У вас нет существующих пользователей!"
				exit
			fi
			echo ""
			echo "Выберите сертификат клиента, который вы хотите отменить"
			tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			if [[ "$NUMBEROFCLIENTS" = '1' ]]; then
				read -p "Выберите пользователя [1]: " CLIENTNUMBER
			else
				read -p "Выберите пользователя [1-$NUMBEROFCLIENTS]: " CLIENTNUMBER
			fi
			CLIENT=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$CLIENTNUMBER"p)
			cd /etc/openvpn/easy-rsa/
			./easyrsa --batch revoke $CLIENT
			./easyrsa gen-crl
			# And restart
			if pgrep systemd-journal; then
				systemctl restart openvpn@server.service
			else
				if [[ "$OS" = 'debian' ]]; then
					/etc/init.d/openvpn restart
				else
					service openvpn restart
				fi
			fi
			echo ""
			echo "Сертификат пользователя $CLIENT отозван"
			exit
			;;
			3)
			echo ""
			read -p "Вы действительно хотите удалить OpenVPN? [y/n]: " -e -i n REMOVE
			if [[ "$REMOVE" = 'y' ]]; then
				PORT=$(grep '^port ' /etc/openvpn/server.conf | cut -d " " -f 2)
				if pgrep firewalld; then
					# Using both permanent and not permanent rules to avoid a firewalld reload.
					firewall-cmd --zone=public --remove-port=$PORT/udp
					firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --permanent --zone=public --remove-port=$PORT/udp
					firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
				fi
                if iptables -L | grep -qE 'REJECT|DROP'; then
					sed -i "/iptables -I INPUT -p udp --dport $PORT -j ACCEPT/d" $RCLOCAL
					sed -i "/iptables -I FORWARD -s 10.8.0.0\/24 -j ACCEPT/d" $RCLOCAL
					sed -i "/iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT/d" $RCLOCAL
				fi
				sed -i '/iptables -t nat -A POSTROUTING -s 10.8.0.0\/24 -j SNAT --to /d' $RCLOCAL
				if [[ "$OS" = 'debian' ]]; then
					apt-get remove --purge -y openvpn openvpn-blacklist
				else
					yum remove openvpn -y
				fi
				rm -rf /etc/openvpn
				rm -rf /usr/share/doc/openvpn*
				echo ""
				echo "OpenVPN удален!"
			else
				echo ""
				echo "Удаление отменено!"
			fi
			exit
			;;
			4) exit;;
		esac
	done
else
	clear
	echo 'Добро пожаловать в установщик OpenVPN'
	echo ""
	# OpenVPN setup and first user creation
	echo "Ответьте на несколько вопросов, прежде чем начать установку"
	echo "Вы можете оставить настройки по умолчанию и просто нажать клавишу ВВОД"
	echo ""
	echo "Укажите адрес IPv4 сетевого интерфейса который вы хотите использовать для OpenVPN"
	read -p "IP адрес: " -e -i $IP IP
	echo ""
	echo "Укажите порт для OpenVPN?"
	read -p "Порт: " -e -i 1194 PORT
	echo ""
	echo "Какие DNS вы хотите использовать для VPN?"
	echo "   1) Current system resolvers"
	echo "   2) OpenDNS"
	echo "   3) Level 3"
	echo "   4) NTT"
	echo "   5) Hurricane Electric"
	echo "   6) Google"
	read -p "DNS [1-6]: " -e -i 1 DNS
	echo ""
	echo "Все готово. Ваш сервер OpenVPN можно настроить прямо сейчас"
	read -n1 -r -p "Нажмите любую клавишу для продолжения..."
		if [[ "$OS" = 'debian' ]]; then
		apt-get update
		apt-get install openvpn iptables openssl -y
	else
		# Else, the distro is CentOS
		yum install epel-release -y
		yum install openvpn iptables openssl wget -y
	fi
	# An old version of easy-rsa was available by default in some openvpn packages
	if [[ -d /etc/openvpn/easy-rsa/ ]]; then
		rm -rf /etc/openvpn/easy-rsa/
	fi
	# Get easy-rsa
	wget --no-check-certificate -O ~/EasyRSA-3.0.0.tgz https://github.com/OpenVPN/easy-rsa/releases/download/3.0.0/EasyRSA-3.0.0.tgz
	tar xzf ~/EasyRSA-3.0.0.tgz -C ~/
	mv ~/EasyRSA-3.0.0/ /etc/openvpn/
	mv /etc/openvpn/EasyRSA-3.0.0/ /etc/openvpn/easy-rsa/
	chown -R root:root /etc/openvpn/easy-rsa/
	rm -rf ~/EasyRSA-3.0.0.tgz
	cd /etc/openvpn/easy-rsa/
	# Create the PKI, set up the CA, the DH params and the server + client certificates
	./easyrsa init-pki
	./easyrsa --batch build-ca nopass
	./easyrsa gen-dh
	echo ""
        read -p "Длинна ключа (сервера): " -e -i 4096 KEYSIZE_SERVER
        read -p "Использовать пароль (сервера)? " -e -i y USEPASS_SERVER
        if [ $USEPASS_SERVER != "y" ]; then
		./easyrsa --keysize=$KEYSIZE_SERVER build-server-full server nopass
	else
		./easyrsa --keysize=$KEYSIZE_SERVER build-server-full server
	fi
	echo ""
        echo "Укажите имя пользователя для сертификата"
        echo "Пожалуйста, используйте только одно слово, без спецсимволов"
        read -p "Имя пользователя: " -e -i client CLIENT
        read -p "Длинна ключа (пользователя): " -e -i 4096 KEYSIZE_CLIENT
        read -p "Использовать пароль (пользователя)? " -e -i y USEPASS_CLIENT
         if [ $USEPASS_CLIENT != "y" ]; then
	         ./easyrsa --keysize=$KEYSIZE_CLIENT build-client-full $CLIENT nopass
         else
                 ./easyrsa --keysize=$KEYSIZE_CLIENT build-client-full $CLIENT
         fi
	./easyrsa gen-crl
	# Move the stuff we need
	cp pki/ca.crt pki/private/ca.key pki/dh.pem pki/issued/server.crt pki/private/server.key /etc/openvpn
	# Generate server.conf
	echo "port $PORT
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt" > /etc/openvpn/server.conf
	echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server.conf
	# DNS
	case $DNS in
		1)
		# Obtain the resolvers from resolv.conf and use them for OpenVPN
		grep -v '#' /etc/resolv.conf | grep 'nameserver' | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | while read line; do
			echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server.conf
		done
		;;
		2)
		echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server.conf
		;;
		3)
		echo 'push "dhcp-option DNS 4.2.2.2"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 4.2.2.4"' >> /etc/openvpn/server.conf
		;;
		4)
		echo 'push "dhcp-option DNS 129.250.35.250"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 129.250.35.251"' >> /etc/openvpn/server.conf
		;;
		5)
		echo 'push "dhcp-option DNS 74.82.42.42"' >> /etc/openvpn/server.conf
		;;
		6)
		echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server.conf
		;;
	esac
	echo "keepalive 10 120
comp-lzo
persist-key
persist-tun
status openvpn-status.log
verb 0
crl-verify /etc/openvpn/easy-rsa/pki/crl.pem" >> /etc/openvpn/server.conf
	# Enable net.ipv4.ip_forward for the system
	if [[ "$OS" = 'debian' ]]; then
		sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
	else
		# CentOS 5 and 6
		sed -i 's|net.ipv4.ip_forward = 0|net.ipv4.ip_forward = 1|' /etc/sysctl.conf
		# CentOS 7
		if ! grep -q "net.ipv4.ip_forward=1" "/etc/sysctl.conf"; then
			echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
		fi
	fi
	# Avoid an unneeded reboot
	echo 1 > /proc/sys/net/ipv4/ip_forward
	# Set NAT for the VPN subnet
	iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j SNAT --to $IP
	sed -i "1 a\iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j SNAT --to $IP" $RCLOCAL
	if pgrep firewalld; then
		# We don't use --add-service=openvpn because that would only work with
		# the default port. Using both permanent and not permanent rules to
		# avoid a firewalld reload.
		firewall-cmd --zone=public --add-port=$PORT/udp
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --permanent --zone=public --add-port=$PORT/udp
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
	fi
    if iptables -L | grep -qE 'REJECT|DROP'; then
		# If iptables has at least one REJECT rule, we asume this is needed.
		# Not the best approach but I can't think of other and this shouldn't
		# cause problems.
		iptables -I INPUT -p udp --dport $PORT -j ACCEPT
		iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT
		iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
		sed -i "1 a\iptables -I INPUT -p udp --dport $PORT -j ACCEPT" $RCLOCAL
		sed -i "1 a\iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT" $RCLOCAL
		sed -i "1 a\iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" $RCLOCAL
	fi
	# And finally, restart OpenVPN
	if [[ "$OS" = 'debian' ]]; then
		# Little hack to check for systemd
		if pgrep systemd-journal; then
			systemctl restart openvpn@server.service
		else
			/etc/init.d/openvpn restart
		fi
	else
		if pgrep systemd-journal; then
			systemctl restart openvpn@server.service
			systemctl enable openvpn@server.service
		else
			service openvpn restart
			chkconfig openvpn on
		fi
	fi
	# Try to detect a NATed connection and ask about it to potential LowEndSpirit users
	EXTERNALIP=$(wget -qO- ipv4.icanhazip.com)
	if [[ "$IP" != "$EXTERNALIP" ]]; then
		echo ""
		echo "Похоже, ваш сервер находится за NAT!"
		echo ""
		echo "Если ваш сервер находится за NAT (LowEndSpirit), укажите внешний IP"
		echo "Если это не так, просто проигнорируйте и оставьте поле пустым"
		read -p "Внешний IP: " -e USEREXTERNALIP
		if [[ "$USEREXTERNALIP" != "" ]]; then
			IP=$USEREXTERNALIP
		fi
	fi
	# client-common.txt is created so we have a template to add further users later
	echo "client
dev tun
proto udp
remote $IP $PORT
resolv-retry infinite
nobind
user nobody
group nogroup
persist-key
persist-tun
remote-cert-tls server
comp-lzo
verb 3" > /etc/openvpn/client-common.txt
	# Generates the custom client.ovpn
	newclient "$CLIENT"
	echo ""
	echo "Готово!"
	echo ""
	echo "Ваша конфигурация пользователя доступна в ~/$CLIENT.ovpn"
	echo "Если вы хотите добавить больше пользователей, запустите этот сценарий еще раз!"
fi

wget https://raw.githubusercontent.com/Varrcan/openvpn/master/openvpn.sh --no-check-certificate -O openvpn.sh; bash openvpn.sh