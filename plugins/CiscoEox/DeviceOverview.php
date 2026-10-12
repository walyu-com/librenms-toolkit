<?php

/*
 * CiscoEox - LibreNMS local plugin
 * Device overview box: hardware / software lifecycle and Cisco PSIRT advisories.
 */

namespace App\Plugins\CiscoEox;

use App\Models\Device;
use App\Models\User;
use App\Plugins\CiscoEox\Lib\Eox;
use App\Plugins\Hooks\DeviceOverviewHook;

class DeviceOverview extends DeviceOverviewHook
{
    // view: resources/views/device-overview.blade.php (default name)

    public function authorize(User $user, Device $device): bool
    {
        // only shown for Cisco OS types known by openVuln
        return Eox::supports((string) $device->os);
    }

    public function data(Device $device, array $settings = []): array
    {
        $user = auth()->user();
        $isAdmin = $user !== null && $user->can('admin');
        $request = request();
        $message = '';
        $toggled = false;

        // "Disable scope" checkbox click: ?eox_adv=...&eox_scope=local|global&eox_set=0|1&eox_t=<csrf>
        if ($request->query('eox_adv') !== null) {
            $toggled = true;
            $tokenOk = hash_equals((string) csrf_token(), (string) $request->query('eox_t', ''));
            if ($isAdmin && $tokenOk) {
                $settings = Eox::setNa(
                    (string) $request->query('eox_scope', ''),
                    (string) $request->query('eox_adv', ''),
                    (int) $device->device_id,
                    (string) $request->query('eox_set', '0') === '1',
                    (string) $user->username
                );
            } else {
                $message = 'Change refused: admin role and a valid session token are required.';
            }
        }

        $version = Eox::normalizeVersion($device->version);
        $hw = Eox::hardwareLifecycle($settings, $device->hardware);
        $sw = Eox::softwareLifecycle($settings, (string) $device->os, $version);

        // cache only: a device page never waits for Cisco (cache filled by bin/refresh.php)
        $error = '';
        $fetched = '';
        $items = [];
        $pending = false;
        try {
            $result = Eox::advisories($settings, (string) $device->os, $version);
            $fetched = $result['fetched'];
            $items = $result['items'];
            $pending = ! empty($result['pending']);
            $error = (string) ($result['error'] ?? '');
        } catch (\Throwable $e) {
            $error = $e->getMessage();
        }

        // apply "not applicable" flags
        $na = Eox::naFlags($settings);
        $deviceKey = (string) $device->device_id;
        $counts = ['Critical' => 0, 'High' => 0, 'Medium' => 0, 'Low' => 0];
        $applicable = 0;
        foreach ($items as &$item) {
            $item['na_global'] = $na['global'][$item['id']] ?? null;
            $item['na_local'] = $na['local'][$deviceKey][$item['id']] ?? null;
            $item['na'] = $item['na_global'] !== null || $item['na_local'] !== null;
            if (! $item['na']) {
                $applicable++;
                if (isset($counts[$item['sir']])) {
                    $counts[$item['sir']]++;
                }
            }
        }
        unset($item);

        // applicable first, then by CVSS descending
        usort($items, function ($a, $b) {
            if ($a['na'] !== $b['na']) {
                return $a['na'] ? 1 : -1;
            }

            return $b['cvss'] <=> $a['cvss'];
        });

        return [
            'title' => 'Cisco lifecycle and advisories',
            'device' => $device,
            'version' => $version,
            'hw' => $hw,
            'sw' => $sw,
            'items' => $items,
            'counts' => $counts,
            'applicable' => $applicable,
            'total' => count($items),
            'fetched' => $fetched,
            'error' => $error,
            'pending' => $pending,
            'message' => $message,
            'isAdmin' => $isAdmin,
            'toggled' => $toggled,
            'baseUrl' => $request->url(),
            'csrf' => (string) csrf_token(),
        ];
    }
}
