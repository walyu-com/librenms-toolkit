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
