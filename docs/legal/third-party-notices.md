# Third-Party Notices

Last reviewed: 2026-05-26
Status: Engineering draft for counsel review

## Active v1 Blocklist Sources

Lava publishes catalog metadata for launch sources and the app fetches selected source URLs directly on the user's device. Lava does not publish third-party blocklist bytes from Lava-controlled R2, Worker, CDN, or app bundle locations.

| Source | License | Lava mode | Project URL | Source URL |
| --- | --- | --- | --- | --- |
| The Block List Project Basic | Unlicense | source_url_only | https://github.com/blocklistproject/Lists | https://blocklistproject.github.io/Lists/basic.txt |
| The Block List Project Malware | Unlicense | source_url_only | https://github.com/blocklistproject/Lists | https://blocklistproject.github.io/Lists/malware.txt |
| The Block List Project Phishing | Unlicense | source_url_only | https://github.com/blocklistproject/Lists | https://blocklistproject.github.io/Lists/phishing.txt |
| The Block List Project Scam | Unlicense | source_url_only | https://github.com/blocklistproject/Lists | https://blocklistproject.github.io/Lists/scam.txt |
| The Block List Project Ransomware | Unlicense | source_url_only | https://github.com/blocklistproject/Lists | https://blocklistproject.github.io/Lists/ransomware.txt |
| Phishing.Database Active Domains | MIT | source_url_only | https://github.com/Phishing-Database/Phishing.Database | https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-domains-ACTIVE.txt |
| HaGeZi Multi Light | GPL-3.0 | source_url_only | https://github.com/hagezi/dns-blocklists | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt |
| HaGeZi Multi Normal | GPL-3.0 | source_url_only | https://github.com/hagezi/dns-blocklists | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/multi-onlydomains.txt |
| HaGeZi Multi PRO mini | GPL-3.0 | source_url_only | https://github.com/hagezi/dns-blocklists | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.mini-onlydomains.txt |
| HaGeZi Multi PRO | GPL-3.0 | source_url_only | https://github.com/hagezi/dns-blocklists | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt |
| HaGeZi Multi PRO++ mini | GPL-3.0 | source_url_only | https://github.com/hagezi/dns-blocklists | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.plus.mini-onlydomains.txt |
| HaGeZi Multi Ultimate mini | GPL-3.0 | source_url_only | https://github.com/hagezi/dns-blocklists | https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/ultimate.mini-onlydomains.txt |
| OISD Small | GPL-3.0 | source_url_only | https://github.com/sjhgvr/oisd | https://raw.githubusercontent.com/sjhgvr/oisd/main/oisd_small.txt |
| OISD Big | GPL-3.0 | source_url_only | https://github.com/sjhgvr/oisd | https://raw.githubusercontent.com/sjhgvr/oisd/main/oisd_big.txt |

## Inactive GPL Review Records

AdGuard DNS Filter remains inactive pending separate review. Active GPL entries above are source-url-only options, off by default, and are not bundled, transformed, or served from Lava infrastructure.

| Source family | Current launch state |
| --- | --- |
| AdGuard DNS Filter | Inactive; license review |
