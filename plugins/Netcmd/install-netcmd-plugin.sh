#!/usr/bin/env bash
# install-netcmd-plugin.sh - installs or updates the "Netcmd" local plugin for LibreNMS
# (menu entry + device page links to the netcmd web tool on port 8090)
# Usage: sudo bash install-netcmd-plugin.sh
set -euo pipefail

LNMS_DIR="/opt/librenms"
PLUGIN_DIR="${LNMS_DIR}/app/Plugins/Netcmd"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash install-netcmd-plugin.sh)"
    exit 1
fi
if [ ! -d "${LNMS_DIR}/app/Plugins" ]; then
    echo "ERROR: ${LNMS_DIR}/app/Plugins not found"
    exit 1
fi
if [ -d "${PLUGIN_DIR}" ]; then
    BACKUP="/root/Netcmd.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${PLUGIN_DIR}" "${BACKUP}"
    echo "Existing plugin saved to ${BACKUP}"
fi

mkdir -p "${PLUGIN_DIR}/resources/views"
cat > "${PLUGIN_DIR}/Settings.php" <<'EOF_NETCMDPLUGIN_0'
<?php

/*
 * Netcmd - LibreNMS local plugin
 * Links to the netcmd web tool (multi-device command runner, port 8090).
 * Settings page: Overview > Plugins > Plugin Admin > Netcmd > Settings
 */

namespace App\Plugins\Netcmd;

use App\Plugins\Hooks\SettingsHook;

class Settings extends SettingsHook
{
    // LibreNMS os handled by netcmd (NETCMD_OS_FILTER default)
    public const OS = ['ios', 'iosxe'];

    /**
     * netcmd base URL: setting, or http://<host used to reach LibreNMS>:8090
     */
    public static function baseUrl(array $settings): string
    {
        $url = trim((string) ($settings['url'] ?? ''));
        if ($url === '') {
            $url = 'http://' . request()->getHost() . ':8090';
        }

        return rtrim($url, '/');
    }

    public function data(array $settings): array
    {
        // view variables prefixed ui_: LibreNMS also spreads the stored settings into the view
        return [
            'settings' => $settings,
            'ui_url' => (string) ($settings['url'] ?? ''),
            'ui_default' => 'http://' . request()->getHost() . ':8090',
        ];
    }
}
EOF_NETCMDPLUGIN_0
cat > "${PLUGIN_DIR}/Menu.php" <<'EOF_NETCMDPLUGIN_1'
<?php

/*
 * Netcmd - LibreNMS local plugin
 * Entry "netcmd" in Overview > Plugins (opens netcmd in a new tab).
 */

namespace App\Plugins\Netcmd;

use App\Models\User;
use App\Plugins\Hooks\MenuEntryHook;

class Menu extends MenuEntryHook
{
    public function authorize(User $user): bool
    {
        return $user->can('global-read');
    }

    public function data(array $settings = []): array
    {
        return ['url' => Settings::baseUrl($settings) . '/'];
    }
}
EOF_NETCMDPLUGIN_1
cat > "${PLUGIN_DIR}/DeviceOverview.php" <<'EOF_NETCMDPLUGIN_2'
<?php

/*
 * Netcmd - LibreNMS local plugin
 * Device overview bar (Cisco IOS / IOS-XE): new netcmd run with this device preselected,
 * and netcmd history of this device.
 */

namespace App\Plugins\Netcmd;

use App\Models\Device;
use App\Models\User;
use App\Plugins\Hooks\DeviceOverviewHook;

class DeviceOverview extends DeviceOverviewHook
{
    public function authorize(User $user, Device $device): bool
    {
        return in_array((string) $device->os, Settings::OS, true) && $user->can('global-read');
    }

    public function data(Device $device, array $settings = []): array
    {
        $base = Settings::baseUrl($settings);
        $ip = (string) $device->hostname; // devices are added by IP in this LibreNMS

        return [
            'runUrl' => $base . '/?' . http_build_query(['ip' => $ip]),
            'historyUrl' => $base . '/devices?' . http_build_query(['ip' => $ip]),
            'homeUrl' => $base . '/',
        ];
    }
}
EOF_NETCMDPLUGIN_2
cat > "${PLUGIN_DIR}/resources/views/menu.blade.php" <<'EOF_NETCMDPLUGIN_3'
<a href="{{ $url }}" target="_blank" rel="noopener"><i class="fa fa-terminal fa-fw fa-lg" aria-hidden="true"></i> netcmd</a>
EOF_NETCMDPLUGIN_3
cat > "${PLUGIN_DIR}/resources/views/device-overview.blade.php" <<'EOF_NETCMDPLUGIN_4'
<div class="tw:mb-5 tw:rounded-lg tw:border tw:border-gray-300 tw:shadow-sm tw:dark:border-dark-gray-200">
    <div class="tw:px-4 tw:py-2.5 tw:bg-neutral-100 tw:text-neutral-700 tw:dark:bg-dark-gray-200 tw:dark:text-dark-white-200">
        <i class="fa fa-terminal fa-fw" aria-hidden="true"></i> <strong>netcmd</strong>
        <a href="{{ $runUrl }}" target="_blank" rel="noopener" style="margin-left:15px">New run on this device</a>
        <a href="{{ $historyUrl }}" target="_blank" rel="noopener" style="margin-left:15px">Command history of this device</a>
        <a href="{{ $homeUrl }}" target="_blank" rel="noopener" style="margin-left:15px">Open netcmd</a>
    </div>
</div>
EOF_NETCMDPLUGIN_4
cat > "${PLUGIN_DIR}/resources/views/settings.blade.php" <<'EOF_NETCMDPLUGIN_5'
<div style="margin: 15px; max-width: 700px;">
    <h4>Netcmd settings</h4>
    <form method="post">
        @csrf
        <table class="table table-condensed">
            <tr>
                <td style="width:180px">netcmd URL</td>
                <td>
                    <input type="text" class="form-control" name="settings[url]" value="{{ $ui_url }}" placeholder="{{ $ui_default }}">
                    <span style="color:#777777;font-size:12px">Empty = {{ $ui_default }} (same host as LibreNMS, port 8090)</span>
                </td>
            </tr>
        </table>
        <button type="submit" class="btn btn-primary">Save</button>
    </form>
</div>
EOF_NETCMDPLUGIN_5

chown -R librenms:librenms "${PLUGIN_DIR}"
find "${PLUGIN_DIR}" -type d -exec chmod 755 {} +
find "${PLUGIN_DIR}" -type f -exec chmod 644 {} +

for f in "${PLUGIN_DIR}/Settings.php" "${PLUGIN_DIR}/Menu.php" "${PLUGIN_DIR}/DeviceOverview.php"; do
    php -l "$f" >/dev/null || { echo "ERROR: syntax error in $f"; exit 1; }
done

sudo -u librenms php "${LNMS_DIR}/artisan" view:clear >/dev/null

echo "OK - Netcmd plugin installed in ${PLUGIN_DIR}"
