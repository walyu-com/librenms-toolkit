<?php

/*
 * Netcmd - LibreNMS local plugin
 * Device overview bar (Cisco IOS / IOS-XE): new netcmd run with this device preselected,
 * MAC trace starting from this device, and netcmd history of this device.
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
            'macTraceUrl' => $base . '/mactrace?' . http_build_query(['ip' => $ip]),
            'historyUrl' => $base . '/devices?' . http_build_query(['ip' => $ip]),
            'homeUrl' => $base . '/',
        ];
    }
}
