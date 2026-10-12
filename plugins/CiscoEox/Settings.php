<?php

/*
 * CiscoEox - LibreNMS local plugin
 * Settings page: Overview > Plugins > Plugin Admin > CiscoEox > Settings
 * Buttons "Rescan hardware" / "Rescan IOS" add a row for every Cisco PID / release
 * train present in LibreNMS that has no lifecycle data yet.
 */

namespace App\Plugins\CiscoEox;

use App\Plugins\CiscoEox\Lib\Eox;
use App\Plugins\Hooks\SettingsHook;

class Settings extends SettingsHook
{
    // view: resources/views/settings.blade.php (default name)

    public function data(array $settings): array
    {
        $rescan = (string) request()->query('rescan', '');
        $devices = $this->loadDevices();
        $inventory = Eox::inventory($devices);

        // "Refresh advisories now" button: same job as the cron (bin/refresh.php)
        $refreshReport = null;
        if ((string) request()->query('refresh', '') === '1') {
            @set_time_limit(300);
            $refreshReport = Eox::refresh($settings, $devices);
        }

        // Rescan buttons: add missing PIDs / trains and save immediately (settings page is admin only)
        if (in_array($rescan, ['hw', 'sw', 'all'], true)) {
            $newHw = ($rescan === 'sw') ? Eox::hwRows($settings) : Eox::rescanHardware(Eox::hwRows($settings), $inventory);
            $newSw = ($rescan === 'hw') ? Eox::swRows($settings) : Eox::rescanSoftware(Eox::swRows($settings), $inventory);
            $strip = fn (array $rows) => array_values(array_map(function ($r) {
                unset($r['new']);

                return $r;
            }, $rows));
            $settings['rows_v'] = '2';
            $settings['hw_rows'] = $strip($newHw);
            $settings['sw_rows'] = $strip($newSw);
            unset($settings['hw'], $settings['sw']);
            $this->saveSettings($settings);
            $markNew = true;
        }

        // hardware rows + device count per row
        $hwRows = Eox::hwRows($settings);
        if (! empty($markNew) && ($rescan === 'hw' || $rescan === 'all')) {
            $hwRows = array_map(function ($r) use ($newHw) {
                foreach ($newHw as $n) {
                    if (! empty($n['new']) && $n['key'] === $r['key']) {
                        $r['new'] = true;
                    }
                }

                return $r;
            }, $hwRows);
        }
        foreach ($hwRows as $i => $row) {
            $hwRows[$i]['devices'] = 0;
            $hwRows[$i]['pids'] = [];
            $hwRows[$i]['lookup'] = Eox::lookupUrl('hw', $row['key']);
        }
        foreach ($inventory['hw'] as $pid => $count) {
            $match = Eox::matchHardware($hwRows, $pid);
            if ($match !== null) {
                $i = array_search($match['key'], array_column($hwRows, 'key'), true);
                $hwRows[$i]['devices'] += $count;
                $hwRows[$i]['pids'][] = $pid . ' (' . $count . ')';
            }
        }

        // software rows + device count per row
        $swRows = Eox::swRows($settings);
        if (! empty($markNew) && ($rescan === 'sw' || $rescan === 'all')) {
            $swRows = array_map(function ($r) use ($newSw) {
                foreach ($newSw as $n) {
                    if (! empty($n['new']) && $n['key'] === $r['key'] && $n['os'] === $r['os']) {
                        $r['new'] = true;
                    }
                }

                return $r;
            }, $swRows);
        }
        foreach ($swRows as $i => $row) {
            $swRows[$i]['devices'] = 0;
            $swRows[$i]['versions'] = [];
            $swRows[$i]['lookup'] = Eox::lookupUrl('sw', $row['key'], $row['os']);
        }
        foreach ($inventory['sw'] as $t) {
            foreach (array_keys($t['versions']) as $v) {
                $match = Eox::matchSoftware($swRows, $t['os'], $v);
                if ($match === null) {
                    continue;
                }
                foreach ($swRows as $i => $row) {
                    if ($row['os'] === $match['os'] && $row['key'] === $match['key']) {
                        $swRows[$i]['versions'][$v] = true;
                        $swRows[$i]['devices'] += $t['vcount'][$v] ?? 0;
                    }
                }
            }
        }
        foreach ($swRows as $i => $row) {
            $swRows[$i]['versions'] = array_keys($row['versions']);
        }

        $na = Eox::naFlags($settings);
        $localCount = 0;
        foreach ($na['local'] as $flags) {
            $localCount += count($flags);
        }

        $todoHw = count(array_filter($hwRows, fn ($r) => $r['status'] === 'todo' && $r['devices'] > 0));
        $todoSw = count(array_filter($swRows, fn ($r) => $r['status'] === 'todo' && $r['devices'] > 0));

        // view variables are prefixed ui_: the LibreNMS settings page also spreads the
        // stored settings (client_id, hw_rows, ...) into the view and would override them
        return [
            'settings' => $settings,
            'ui_client_id' => (string) ($settings['client_id'] ?? ''),
            'ui_client_secret' => (string) ($settings['client_secret'] ?? ''),
            'ui_cache_hours' => (string) ($settings['cache_hours'] ?? '72'),
            'ui_refresh_report' => $refreshReport,
            'ui_last_run' => Eox::lastRun(),
            'ui_hw_rows' => $hwRows,
            'ui_sw_rows' => $swRows,
            'ui_todo_hw' => $todoHw,
            'ui_todo_sw' => $todoSw,
            'ui_rescan' => $rescan,
            'ui_na_json' => (string) ($settings['na'] ?? ''),
            'ui_na_global' => $na['global'],
            'ui_na_local_count' => $localCount,
            'ui_page_url' => request()->url(),
        ];
    }

    protected function saveSettings(array $settings): void
    {
        \PluginManager::setSettings(Eox::PLUGIN, $settings);
    }

    /**
     * Cisco devices known by LibreNMS (enabled only).
     */
    protected function loadDevices(): array
    {
        return \App\Models\Device::query()
            ->where('disabled', 0)
            ->whereIn('os', array_keys(Eox::OS_MAP))
            ->get(['os', 'hardware', 'version'])
            ->map(fn ($d) => ['os' => $d->os, 'hardware' => $d->hardware, 'version' => $d->version])
            ->all();
    }
}
