# SPDX-FileCopyrightText: 2026 AK Shumkar
#
# SPDX-License-Identifier: GPL-2.0-or-later

if (description)
{
  script_oid("1.3.6.1.4.1.25623.1.0.900001");
  script_version("2026-03-31T00:00:00+0000");
  script_tag(name:"last_modification", value:"2026-03-31 00:00:00 +0000");
  script_tag(name:"creation_date", value:"2026-03-31 00:00:00 +0000");
  script_tag(name:"cvss_base_vector", value:"AV:N/AC:L/Au:N/C:N/I:N/A:N");
  script_tag(name:"cvss_base", value:"0.0");
  script_name("UDP Port Scanner");
  script_category(ACT_SCANNER);
  script_family("Port scanners");
  script_copyright("Copyright (C) 2026 AK Shumkar");
  script_dependencies("2011/synscan.nasl");

  script_tag(name:"summary", value:"Runs AK Shumkar UDP scanner backend.");
  script_tag(name:"qod_type", value:"remote_banner");

  exit(0);
}

plugin_run_udp_scanner();
exit(0);
