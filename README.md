`````
wget -O /usr/local/bin/argo https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/argo.sh && chmod +x /usr/local/bin/argo && argo install
`````
ufwssh
`````
bash <(curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/ufwssh.sh)
`````
docker+komari+sublinkpro+cf隧道
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/KSC-docker.sh | bash
`````
komari-cf
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/komari_cf.sh -o /usr/local/bin/komari && chmod +x /usr/local/bin/komari && komari
`````
uufw防火墙
`````
curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/uufw.sh -o /usr/local/bin/uufw && chmod +x /usr/local/bin/uufw && uufw
`````

dns
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/dns.sh | sh
`````

dnsplus-DOT
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/dnsplus.sh | bash
`````

DOH
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/DOH.sh | bash
`````


check-doh dns
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/doh-check.sh | bash
`````


check-dot dns
`````
wget -qO- https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/dns-check.sh | bash
`````
