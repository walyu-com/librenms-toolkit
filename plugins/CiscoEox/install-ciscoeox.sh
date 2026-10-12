#!/usr/bin/env bash
# install-ciscoeox.sh - installs or updates the CiscoEox local plugin for LibreNMS
# Usage: sudo bash install-ciscoeox.sh
set -euo pipefail

LNMS_DIR="/opt/librenms"
PLUGIN_DIR="${LNMS_DIR}/app/Plugins/CiscoEox"
CRON_FILE="/etc/cron.d/librenms-ciscoeox"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash install-ciscoeox.sh)"
    exit 1
fi
if [ ! -d "${LNMS_DIR}/app/Plugins" ]; then
    echo "ERROR: ${LNMS_DIR}/app/Plugins not found"
    exit 1
fi

if [ -d "${PLUGIN_DIR}" ]; then
    BACKUP="/root/CiscoEox.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${PLUGIN_DIR}" "${BACKUP}"
    echo "Existing plugin saved to ${BACKUP}"
fi

mkdir -p "${PLUGIN_DIR}/Lib" "${PLUGIN_DIR}/bin" "${PLUGIN_DIR}/resources/views"
cat > "${PLUGIN_DIR}/Lib/Eox.php" <<'EOF_CISCOEOX_0'
<?php

/*
 * CiscoEox - LibreNMS local plugin
 * Helper class: Cisco PSIRT openVuln queries, lifecycle (EoL) lookup,
 * "not applicable" (disable scope Local / Global) storage.
 *
 * This file lives in a sub folder on purpose: every *.php file placed
 * directly in app/Plugins/CiscoEox/ must be a hook class.
 */

namespace App\Plugins\CiscoEox\Lib;

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;

class Eox
{
    public const PLUGIN = 'CiscoEox';

    public const TOKEN_URL = 'https://id.cisco.com/oauth2/default/v1/token';

    public const API_BASE = 'https://apix.cisco.com/security/advisories/v2';

    // LibreNMS os => openVuln OSType
    public const OS_MAP = [
        'ios' => 'ios',
        'iosxe' => 'iosxe',
        'nxos' => 'nxos',
        'asa' => 'asa',
    ];

    // PID_PREFIX|END_OF_SALE|END_OF_SECURITY_SUPPORT|LAST_DATE_OF_SUPPORT|BULLETIN_URL
    public const DEFAULT_HW = <<<'TXT'
# PID prefix|End-of-Sale|End of Vulnerability/Security Support|Last Date of Support|Bulletin URL[|status|checked]
C1000-|2025-04-30|2028-04-30|2030-04-30|https://www.cisco.com/c/en/us/products/collateral/switches/catalyst-1000-series-switches/catalyst-1000-series-switches-eol.html
WS-C2960X-|2022-10-31|2027-10-31|2027-10-31|https://www.cisco.com/c/en/us/products/collateral/switches/catalyst-2960-x-series-switches/eos-eol-notice-c51-744432.html
WS-C2960G-24TC-L|2012-07-31||2017-07-31|https://www.cisco.com/c/en/us/products/collateral/switches/catalyst-2960-series-switches/end_of_life_c51-674040.html
WS-C3750X-48PF-E|2016-10-30|2019-10-30|2021-10-31|https://www.cisco.com/c/en/us/products/collateral/switches/catalyst-3560-x-series-switches/eos-eol-notice-c51-736139.html
C9200-||||https://www.cisco.com/c/en/us/products/switches/catalyst-9200-series-switches/eos-eol-notice-listing.html|none|2026-10-06
C9300-||||https://www.cisco.com/c/en/us/products/switches/catalyst-9300-series-switches/eos-eol-notice-listing.html|none|2026-10-06
TXT;

    // OS|TRAIN|END_OF_SW_MAINTENANCE|END_OF_SECURITY_SUPPORT|LAST_DATE_OF_SUPPORT|BULLETIN_URL
    public const DEFAULT_SW = <<<'TXT'
# os|train|End of SW Maintenance|End of Vulnerability/Security Support|Last Date of Support|Bulletin URL
iosxe|17.3|2023-03-31|2023-09-30|2027-03-31|https://www.cisco.com/c/en/us/products/collateral/ios-nx-os-software/ios-xe-17/ios-xe-17-3-x-eol.html
iosxe|17.12|2026-03-30|2027-09-30|2028-03-31|https://www.cisco.com/c/en/us/products/collateral/ios-nx-os-software/ios-xe-17/ios-xe-17-12-x-eol.html
iosxe|17.16|2026-01-13|2026-01-13|2028-06-30|https://www.cisco.com/c/en/us/products/collateral/ios-nx-os-software/ios-xe-17/ios-xe-17-16-x-eol.html
ios|15.2(4)E|2019-05-01|2020-04-30|2023-04-30|https://www.cisco.com/c/en/us/products/collateral/switches/catalyst-4500-series-switches/eos-eol-notice-c51-739919.html
TXT;

    public static function supports(string $os): bool
    {
        return isset(self::OS_MAP[$os]);
    }

    /**
     * "CAT9K_IOSXE 17.16.1" -> "17.16.1" ; "15.2(7)E11" -> "15.2(7)E11"
     */
    public static function normalizeVersion(?string $version): string
    {
        $version = trim((string) $version);
        if ($version === '') {
            return '';
        }
        $parts = preg_split('/\s+/', $version);

        return (string) end($parts);
    }

    /**
     * OAuth2 client credentials token, cached until shortly before expiry.
     */
    public static function token(array $settings): string
    {
        $id = trim((string) ($settings['client_id'] ?? ''));
        $secret = trim((string) ($settings['client_secret'] ?? ''));
        if ($id === '' || $secret === '') {
            throw new \RuntimeException('Cisco API credentials not set (Overview > Plugins > Plugin Admin > CiscoEox > Settings).');
        }

        $key = 'ciscoeox:token:' . sha1($id . '|' . $secret);
        $token = Cache::get($key);
        if (is_string($token) && $token !== '') {
            return $token;
        }

        $response = Http::asForm()->timeout(20)->post(self::TOKEN_URL, [
            'grant_type' => 'client_credentials',
            'client_id' => $id,
            'client_secret' => $secret,
        ]);
        if (! $response->successful()) {
            throw new \RuntimeException('Cisco token request failed: HTTP ' . $response->status());
        }
        $token = (string) $response->json('access_token', '');
        if ($token === '') {
            throw new \RuntimeException('Cisco token request returned no access_token.');
        }
        $ttl = max(60, (int) $response->json('expires_in', 3600) - 300);
        Cache::put($key, $token, $ttl);

        return $token;
    }

    /**
     * Advisories for one OS type and version.
     * Web pages call it with $fetch = false: cache only, never a network call, so a
     * device page is never slowed down by Cisco. The background job
     * (bin/refresh.php, cron) and the "Refresh advisories now" button use $fetch = true.
     *
     * @return array{fetched: string, items: array, pending?: bool, error?: string}
     */
    public static function advisories(array $settings, string $os, string $version, bool $fetch = false): array
    {
        $type = self::OS_MAP[$os] ?? null;
        if ($type === null || $version === '') {
            return ['fetched' => '', 'items' => []];
        }

        $key = 'ciscoeox:adv:' . $type . ':' . $version;
        if (! $fetch) {
            $cached = Cache::get($key);
            if (is_array($cached) && isset($cached['items'])) {
                return $cached;
            }

            return ['fetched' => '', 'items' => [], 'pending' => true, 'error' => (string) Cache::get('ciscoeox:err:' . $type . ':' . $version, '')];
        }

        try {
            $response = Http::withToken(self::token($settings))
                ->acceptJson()
                ->connectTimeout(5)
                ->timeout(30)
                ->get(self::API_BASE . '/OSType/' . $type, ['version' => $version]);

            if (! $response->successful()) {
                $detail = (string) $response->json('errorMessage', '');
                throw new \RuntimeException('openVuln request failed for ' . $type . ' ' . $version . ': HTTP ' . $response->status() . ($detail !== '' ? ' - ' . $detail : ''));
            }
        } catch (\Throwable $e) {
            Cache::put('ciscoeox:err:' . $type . ':' . $version, $e->getMessage(), 86400);
            throw $e;
        }

        $items = [];
        foreach ((array) $response->json('advisories', []) as $adv) {
            $items[] = [
                'id' => (string) ($adv['advisoryId'] ?? ''),
                'title' => (string) ($adv['advisoryTitle'] ?? ''),
                'sir' => (string) ($adv['sir'] ?? ''),
                'cvss' => (float) ($adv['cvssBaseScore'] ?? 0),
                'cves' => array_values(array_filter((array) ($adv['cves'] ?? []), fn ($c) => $c !== 'NA')),
                'fixed' => array_values((array) ($adv['firstFixed'] ?? [])),
                'url' => (string) ($adv['publicationUrl'] ?? ''),
                'published' => substr((string) ($adv['firstPublished'] ?? ''), 0, 10),
                'updated' => substr((string) ($adv['lastUpdated'] ?? ''), 0, 10),
            ];
        }

        $hours = max(1, (int) ($settings['cache_hours'] ?? 72));
        $data = ['fetched' => date('Y-m-d H:i'), 'items' => $items];
        Cache::put($key, $data, $hours * 3600);
        Cache::forget('ciscoeox:err:' . $type . ':' . $version);

        return $data;
    }

    /**
     * Fetch advisories for every distinct (os, version) present. Used by cron and the settings button.
     *
     * @param  iterable  $devices  objects or arrays with os, version
     */
    public static function refresh(array $settings, iterable $devices): array
    {
        $pairs = [];
        foreach ($devices as $d) {
            $d = (array) $d;
            $os = (string) ($d['os'] ?? '');
            $version = self::normalizeVersion($d['version'] ?? '');
            if (self::supports($os) && $version !== '') {
                $pairs[$os . '|' . $version] = [$os, $version];
            }
        }
        ksort($pairs);

        $report = ['date' => date('Y-m-d H:i'), 'ok' => 0, 'failed' => 0, 'details' => []];
        $start = microtime(true);
        foreach ($pairs as [$os, $version]) {
            $t0 = microtime(true);
            try {
                $data = self::advisories($settings, $os, $version, true);
                $report['ok']++;
                $report['details'][] = sprintf('OK   %s %s: %d advisories (%.1f s)', $os, $version, count($data['items']), microtime(true) - $t0);
            } catch (\Throwable $e) {
                $report['failed']++;
                $report['details'][] = sprintf('FAIL %s %s: %s', $os, $version, $e->getMessage());
            }
            usleep(250000); // stay far below the 5 requests per second quota
        }
        $report['seconds'] = round(microtime(true) - $start, 1);
        Cache::forever('ciscoeox:lastrun', $report);

        return $report;
    }

    public static function lastRun(): ?array
    {
        $r = Cache::get('ciscoeox:lastrun');

        return is_array($r) ? $r : null;
    }

    /**
     * Parse "a|b|c" lines, ignoring blank lines and lines starting with #.
     *
     * @return array<int, array<int, string>>
     */
    public static function parseLines(string $text): array
    {
        $rows = [];
        foreach (preg_split('/\r\n|\r|\n/', $text) as $line) {
            $line = trim($line);
            if ($line === '' || str_starts_with($line, '#')) {
                continue;
            }
            $rows[] = array_map('trim', explode('|', $line));
        }

        return $rows;
    }

    /**
     * Normalize one stored row (hardware or software).
     * status: todo = to be completed, eol = EoL announced (dates), none = no EoL announced (checked)
     */
    protected static function cleanRow(array $row, bool $software): ?array
    {
        if (! empty($row['remove'])) {
            return null;
        }
        $key = trim((string) ($row['key'] ?? ''));
        if ($key === '') {
            return null;
        }
        $status = (string) ($row['status'] ?? 'todo');
        if (! in_array($status, ['todo', 'eol', 'none'], true)) {
            $status = 'todo';
        }
        $out = [
            'key' => $software ? $key : strtoupper($key),
            'd1' => trim((string) ($row['d1'] ?? '')),
            'd2' => trim((string) ($row['d2'] ?? '')),
            'd3' => trim((string) ($row['d3'] ?? '')),
            'url' => trim((string) ($row['url'] ?? '')),
            'status' => $status,
            'checked' => trim((string) ($row['checked'] ?? '')),
        ];
        if ($software) {
            $out['os'] = strtolower(trim((string) ($row['os'] ?? '')));
        }

        return $out;
    }

    /**
     * Rows from the old text format (or the built-in defaults).
     */
    protected static function rowsFromText(string $text, bool $software): array
    {
        $rows = [];
        foreach (self::parseLines($text) as $f) {
            if ($software) {
                $row = ['os' => $f[0] ?? '', 'key' => $f[1] ?? '', 'd1' => $f[2] ?? '', 'd2' => $f[3] ?? '', 'd3' => $f[4] ?? '', 'url' => $f[5] ?? ''];
            } else {
                $row = ['key' => $f[0] ?? '', 'd1' => $f[1] ?? '', 'd2' => $f[2] ?? '', 'd3' => $f[3] ?? '', 'url' => $f[4] ?? ''];
            }
            // optional trailing fields: status|checked
            $extra = $software ? 6 : 5;
            $row['status'] = $f[$extra] ?? ((($row['d1'] . $row['d2'] . $row['d3']) !== '') ? 'eol' : 'todo');
            $row['checked'] = $f[$extra + 1] ?? '';
            $clean = self::cleanRow($row, $software);
            if ($clean !== null) {
                $rows[] = $clean;
            }
        }

        return $rows;
    }

    /**
     * Hardware rows: hw_rows (current format), else hw text (old format), else defaults.
     */
    public static function hwRows(array $settings): array
    {
        // rows_v = 2: table format saved by the settings page (an empty table stays empty)
        if (($settings['rows_v'] ?? '') === '2' || (isset($settings['hw_rows']) && is_array($settings['hw_rows']))) {
            $rows = is_array($settings['hw_rows'] ?? null) ? $settings['hw_rows'] : [];

            return array_values(array_filter(array_map(fn ($r) => is_array($r) ? self::cleanRow($r, false) : null, $rows)));
        }

        return self::rowsFromText((string) ($settings['hw'] ?? self::DEFAULT_HW), false);
    }

    public static function swRows(array $settings): array
    {
        // rows_v = 2: table format saved by the settings page (an empty table stays empty)
        if (($settings['rows_v'] ?? '') === '2' || (isset($settings['sw_rows']) && is_array($settings['sw_rows']))) {
            $rows = is_array($settings['sw_rows'] ?? null) ? $settings['sw_rows'] : [];

            return array_values(array_filter(array_map(fn ($r) => is_array($r) ? self::cleanRow($r, true) : null, $rows)));
        }

        return self::rowsFromText((string) ($settings['sw'] ?? self::DEFAULT_SW), true);
    }

    /**
     * Hardware lifecycle: longest PID prefix match.
     */
    public static function hardwareLifecycle(array $settings, ?string $hardware): ?array
    {
        return self::matchHardware(self::hwRows($settings), (string) $hardware);
    }

    public static function matchHardware(array $rows, string $hardware): ?array
    {
        $pid = strtoupper(trim($hardware));
        if ($pid === '') {
            return null;
        }
        $best = null;
        foreach ($rows as $row) {
            if (str_starts_with($pid, $row['key']) && ($best === null || strlen($row['key']) > strlen($best['key']))) {
                $best = $row;
            }
        }

        return $best;
    }

    /**
     * Software lifecycle: longest train match for this os.
     * Train "17.1" must not match "17.16.1": when the train ends with a digit,
     * the next character must not be a digit. Train "15.2(4)E" matches "15.2(4)E10".
     */
    public static function softwareLifecycle(array $settings, string $os, string $version): ?array
    {
        return self::matchSoftware(self::swRows($settings), $os, $version);
    }

    public static function matchSoftware(array $rows, string $os, string $version): ?array
    {
        if ($version === '') {
            return null;
        }
        $best = null;
        foreach ($rows as $row) {
            $train = $row['key'];
            if ($row['os'] !== $os || ! str_starts_with($version, $train)) {
                continue;
            }
            $next = substr($version, strlen($train), 1);
            if ($next !== '' && ctype_digit($next) && ctype_digit(substr($train, -1))) {
                continue;
            }
            if ($best === null || strlen($train) > strlen($best['key'])) {
                $best = $row;
            }
        }

        return $best;
    }

    /**
     * Release train of a version:
     * ios "15.2(7)E11" -> "15.2(7)E", "15.0(2)SE11" -> "15.0(2)SE"
     * iosxe / nxos / asa "17.16.1" -> "17.16"
     */
    public static function trainOf(string $os, string $version): string
    {
        if ($version === '') {
            return '';
        }
        if ($os === 'ios') {
            if (preg_match('/^(.*[A-Za-z])\d*$/', $version, $m)) {
                return $m[1];
            }

            return $version;
        }
        if (preg_match('/^(\d+\.\d+)/', $version, $m)) {
            return $m[1];
        }

        return $version;
    }

    /**
     * Inventory of Cisco devices present: distinct PIDs and release trains with device counts.
     *
     * @param  iterable  $devices  objects or arrays with os, hardware, version
     */
    public static function inventory(iterable $devices): array
    {
        $hw = [];
        $sw = [];
        foreach ($devices as $d) {
            $d = (array) $d;
            $os = (string) ($d['os'] ?? '');
            if (! self::supports($os)) {
                continue;
            }
            $pid = strtoupper(trim((string) ($d['hardware'] ?? '')));
            if ($pid !== '') {
                $hw[$pid] = ($hw[$pid] ?? 0) + 1;
            }
            $version = self::normalizeVersion($d['version'] ?? '');
            $train = self::trainOf($os, $version);
            if ($train !== '') {
                $k = $os . '|' . $train;
                $sw[$k] ??= ['os' => $os, 'train' => $train, 'count' => 0, 'versions' => [], 'vcount' => []];
                $sw[$k]['count']++;
                $sw[$k]['versions'][$version] = true;
                $sw[$k]['vcount'][$version] = ($sw[$k]['vcount'][$version] ?? 0) + 1;
            }
        }
        ksort($hw);
        ksort($sw);

        return ['hw' => $hw, 'sw' => $sw];
    }

    /**
     * Rescan: add a "todo" row for every PID present that no row covers.
     */
    public static function rescanHardware(array $rows, array $inventory): array
    {
        foreach (array_keys($inventory['hw']) as $pid) {
            if (self::matchHardware($rows, $pid) === null) {
                $rows[] = ['key' => $pid, 'd1' => '', 'd2' => '', 'd3' => '', 'url' => '', 'status' => 'todo', 'checked' => '', 'new' => true];
            }
        }

        return $rows;
    }

    /**
     * Rescan: add a "todo" row for every release train present that no row covers.
     */
    public static function rescanSoftware(array $rows, array $inventory): array
    {
        foreach ($inventory['sw'] as $t) {
            $covered = false;
            foreach (array_keys($t['versions']) as $v) {
                if (self::matchSoftware($rows, $t['os'], $v) !== null) {
                    $covered = true;
                    break;
                }
            }
            if (! $covered) {
                $rows[] = ['os' => $t['os'], 'key' => $t['train'], 'd1' => '', 'd2' => '', 'd3' => '', 'url' => '', 'status' => 'todo', 'checked' => '', 'new' => true];
            }
        }

        return $rows;
    }

    /**
     * Web search link for the official Cisco EoL bulletin.
     */
    public static function lookupUrl(string $type, string $key, string $os = ''): string
    {
        if ($type === 'hw') {
            $q = 'site:cisco.com "End-of-Sale and End-of-Life Announcement" "' . $key . '"';
        } else {
            $label = $os === 'ios' ? 'IOS ' : ($os === 'iosxe' ? 'IOS XE ' : strtoupper($os) . ' ');
            $q = 'site:cisco.com "End-of-Sale and End-of-Life Announcement" "' . $label . $key . '"';
        }

        return 'https://www.google.com/search?q=' . rawurlencode($q);
    }

    /**
     * Date status: past / soon (< 365 days) / ok / unknown.
     */
    public static function dateStatus(string $date): string
    {
        $ts = strtotime($date);
        if ($date === '' || $ts === false) {
            return 'unknown';
        }
        $today = strtotime(date('Y-m-d'));
        if ($ts < $today) {
            return 'past';
        }
        if ($ts < $today + 365 * 86400) {
            return 'soon';
        }

        return 'ok';
    }

    /**
     * @return array{global: array<string, array>, local: array<string, array<string, array>>}
     */
    public static function naFlags(array $settings): array
    {
        $na = json_decode((string) ($settings['na'] ?? ''), true);
        if (! is_array($na)) {
            $na = [];
        }

        return [
            'global' => is_array($na['global'] ?? null) ? $na['global'] : [],
            'local' => is_array($na['local'] ?? null) ? $na['local'] : [],
        ];
    }

    /**
     * Set or clear a "not applicable" flag and save the plugin settings.
     * Always re-reads the stored settings first so nothing else is lost.
     */
    public static function setNa(string $scope, string $advisoryId, int $deviceId, bool $set, string $username): array
    {
        $settings = \PluginManager::getSettings(self::PLUGIN);
        $na = self::naFlags($settings);
        $entry = ['user' => $username, 'date' => date('Y-m-d H:i')];

        if ($scope === 'global') {
            if ($set) {
                $na['global'][$advisoryId] = $entry;
            } else {
                unset($na['global'][$advisoryId]);
            }
        } elseif ($scope === 'local') {
            $dev = (string) $deviceId;
            if ($set) {
                $na['local'][$dev][$advisoryId] = $entry;
            } else {
                unset($na['local'][$dev][$advisoryId]);
                if (empty($na['local'][$dev])) {
                    unset($na['local'][$dev]);
                }
            }
        } else {
            return $settings;
        }

        $settings['na'] = json_encode($na);
        \PluginManager::setSettings(self::PLUGIN, $settings);

        return $settings;
    }
}
EOF_CISCOEOX_0
cat > "${PLUGIN_DIR}/DeviceOverview.php" <<'EOF_CISCOEOX_1'
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
EOF_CISCOEOX_1
cat > "${PLUGIN_DIR}/Settings.php" <<'EOF_CISCOEOX_2'
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
EOF_CISCOEOX_2
cat > "${PLUGIN_DIR}/resources/views/device-overview.blade.php" <<'EOF_CISCOEOX_3'
@php
    $statusColor = ['past' => '#d9534f', 'soon' => '#f0ad4e', 'ok' => '#5cb85c', 'unknown' => '#999999'];
    $sirColor = ['Critical' => '#a94442', 'High' => '#d9534f', 'Medium' => '#f0ad4e', 'Low' => '#5bc0de'];
    $badge = function ($date) use ($statusColor) {
        if ($date === null || $date === '') {
            return '<span style="color:#999999">-</span>';
        }
        $s = \App\Plugins\CiscoEox\Lib\Eox::dateStatus($date);
        return '<span style="color:#fff;background:' . $statusColor[$s] . ';padding:1px 6px;border-radius:3px;white-space:nowrap">' . e($date) . '</span>';
    };
    $toggleUrl = function ($adv, $scope, $set) use ($baseUrl, $csrf) {
        return $baseUrl . '?' . http_build_query([
            'eox_adv' => $adv,
            'eox_scope' => $scope,
            'eox_set' => $set ? '1' : '0',
            'eox_t' => $csrf,
        ]);
    };
@endphp
<div class="tw:mb-5 tw:rounded-lg tw:border tw:border-gray-300 tw:shadow-sm tw:dark:border-dark-gray-200" id="ciscoeox">
    <div class="tw:px-4 tw:py-2.5 tw:bg-neutral-100 tw:border-b tw:border-gray-300 tw:text-neutral-700 tw:dark:bg-dark-gray-200 tw:dark:border-zinc-800 tw:dark:text-dark-white-200">
        <strong>{{ $title }}</strong>
        <span style="margin-left:10px">{{ $device->hardware }} - {{ $device->os }} {{ $version }}</span>
    </div>
    <div class="tw:px-4 tw:py-2 tw:bg-white tw:dark:bg-dark-gray-400">

        @if($message !== '')
            <div style="color:#d9534f;margin-bottom:6px">{{ $message }}</div>
        @endif

        <table class="table table-condensed" style="margin-bottom:8px">
            @foreach([['Hardware', $hw, 'End-of-Sale'], ['Software', $sw, 'End of SW maintenance']] as [$label, $lc, $firstLabel])
                <tr>
                    <th style="width:120px">{{ $label }}</th>
                    @if($lc && $lc['status'] === 'eol')
                        <td>{{ $firstLabel }} {!! $badge($lc['d1']) !!}</td>
                        <td>End of security {!! $badge($lc['d2']) !!}</td>
                        <td>Last Date of Support {!! $badge($lc['d3']) !!}</td>
                        <td>@if($lc['url'] !== '')<a href="{{ $lc['url'] }}" target="_blank" rel="noopener">Bulletin</a>@endif</td>
                    @elseif($lc && $lc['status'] === 'none')
                        <td colspan="4">No EoL announced by Cisco (checked {{ $lc['checked'] !== '' ? $lc['checked'] : '-' }})</td>
                    @else
                        <td colspan="4" style="color:#f0ad4e">EoL data to complete: Overview &gt; Plugins &gt; Plugin Admin &gt; CiscoEox &gt; Settings &gt; Rescan {{ $label === 'Hardware' ? 'hardware' : 'IOS' }}</td>
                    @endif
                </tr>
            @endforeach
        </table>

        @if($pending)
            <div style="color:#f0ad4e">
                Advisories not loaded yet for this version: they are fetched in the background (cron every 6 h)
                or with "Refresh advisories now" in Plugin Admin &gt; CiscoEox &gt; Settings.
                @if($error !== '')<br><span style="color:#d9534f">Last attempt: {{ $error }}</span>@endif
            </div>
        @elseif($error !== '')
            <div style="color:#d9534f">{{ $error }}</div>
        @else
            <details @if($toggled) open @endif>
                <summary style="cursor:pointer">
                    <strong>Advisories: {{ $applicable }} applicable / {{ $total }}</strong>
                    @foreach($counts as $sir => $n)
                        @if($n > 0)
                            <span style="color:#fff;background:{{ $sirColor[$sir] }};padding:1px 6px;border-radius:3px;margin-left:4px">{{ $sir }} {{ $n }}</span>
                        @endif
                    @endforeach
                    <span style="color:#999999;margin-left:8px">(openVuln, fetched {{ $fetched }})</span>
                </summary>

                @if($total === 0)
                    <div style="margin-top:6px">No advisory returned for this version.</div>
                @else
                    <table class="table table-condensed table-hover" style="margin-top:6px;font-size:12px">
                        <thead>
                            <tr>
                                <th>Severity</th>
                                <th>CVSS</th>
                                <th>Advisory</th>
                                <th>CVE</th>
                                <th>First fixed</th>
                                <th>Published</th>
                                <th style="white-space:nowrap">Disable scope<br>Local / Global</th>
                            </tr>
                        </thead>
                        <tbody>
                        @foreach($items as $it)
                            <tr @if($it['na']) style="color:#aaaaaa" @endif>
                                <td>
                                    @if($it['na'])
                                        {{ $it['sir'] }}
                                    @else
                                        <span style="color:#fff;background:{{ $sirColor[$it['sir']] ?? '#999999' }};padding:1px 6px;border-radius:3px">{{ $it['sir'] }}</span>
                                    @endif
                                </td>
                                <td>{{ number_format($it['cvss'], 1) }}</td>
                                <td>
                                    <a href="{{ $it['url'] }}" target="_blank" rel="noopener" @if($it['na']) style="color:#aaaaaa" @endif>{{ $it['id'] }}</a><br>
                                    {{ $it['title'] }}
                                </td>
                                <td>{{ implode(', ', $it['cves']) }}</td>
                                <td>{{ implode(', ', $it['fixed']) }}</td>
                                <td style="white-space:nowrap">{{ $it['published'] }}</td>
                                <td style="white-space:nowrap">
                                    <input type="checkbox" class="ciscoeox-na"
                                           title="{{ $it['na_local'] ? 'Local: ' . $it['na_local']['user'] . ' ' . $it['na_local']['date'] : 'Not applicable on this device' }}"
                                           data-href="{{ $toggleUrl($it['id'], 'local', ! $it['na_local']) }}"
                                           @if($it['na_local']) checked @endif
                                           @if(! $isAdmin) disabled @endif>
                                    /
                                    <input type="checkbox" class="ciscoeox-na"
                                           title="{{ $it['na_global'] ? 'Global: ' . $it['na_global']['user'] . ' ' . $it['na_global']['date'] : 'Not applicable on all devices' }}"
                                           data-href="{{ $toggleUrl($it['id'], 'global', ! $it['na_global']) }}"
                                           @if($it['na_global']) checked @endif
                                           @if(! $isAdmin) disabled @endif>
                                </td>
                            </tr>
                        @endforeach
                        </tbody>
                    </table>
                @endif
            </details>
        @endif
    </div>
</div>
<script>
    (function () {
        document.querySelectorAll('#ciscoeox .ciscoeox-na').forEach(function (cb) {
            cb.addEventListener('change', function () {
                window.location.href = cb.dataset.href;
            });
        });
        // remove the one-shot parameters from the address bar after a change
        if (window.location.search.indexOf('eox_adv=') !== -1 && window.history.replaceState) {
            window.history.replaceState(null, '', window.location.pathname + '#ciscoeox');
        }
    })();
</script>
EOF_CISCOEOX_3
cat > "${PLUGIN_DIR}/resources/views/settings.blade.php" <<'EOF_CISCOEOX_4'
@php
    $statusLabels = ['todo' => 'To complete', 'eol' => 'EoL announced', 'none' => 'No EoL announced'];
@endphp
<div style="margin: 15px;">
    <h4>CiscoEox settings</h4>

    <form method="post" id="ciscoeox-settings">
        @csrf
        <input type="hidden" name="settings[rows_v]" value="2">

        <h5 style="margin-top:20px"><strong>Cisco PSIRT openVuln API</strong> (apiconsole.cisco.com, Client Credentials)</h5>
        <table class="table table-condensed" style="max-width:700px">
            <tr>
                <td style="width:180px">Client ID (Key)</td>
                <td><input type="text" class="form-control" name="settings[client_id]" value="{{ $ui_client_id }}" autocomplete="off"></td>
            </tr>
            <tr>
                <td>Client Secret</td>
                <td><input type="password" class="form-control" name="settings[client_secret]" value="{{ $ui_client_secret }}" autocomplete="new-password"></td>
            </tr>
            <tr>
                <td>Cache (hours)</td>
                <td><input type="number" min="1" class="form-control" name="settings[cache_hours]" value="{{ $ui_cache_hours }}"></td>
            </tr>
        </table>

        <h5 style="margin-top:20px">
            <strong>Advisories cache</strong>
            <a href="{{ $ui_page_url }}?refresh=1" class="btn btn-default btn-sm" style="margin-left:10px"
               onclick="this.innerText='Refreshing, please wait...'">Refresh advisories now</a>
        </h5>
        <p style="color:#777777">Device pages read the cache only. The cache is filled by the background job
            (/etc/cron.d/librenms-ciscoeox, every 6 h) or by this button. Keep "Cache (hours)" above 6 (default 72).</p>
        @php $run = $ui_refresh_report ?? $ui_last_run; @endphp
        @if($run)
            <p>Last refresh: {{ $run['date'] }} - OK {{ $run['ok'] }} / failed {{ $run['failed'] }} - {{ $run['seconds'] ?? '' }} s</p>
            <pre style="font-size:11px;max-height:200px;overflow:auto">{{ implode("\n", $run['details']) }}</pre>
        @else
            <p style="color:#f0ad4e">No refresh has run yet.</p>
        @endif

        {{-- ===== Hardware ===== --}}
        <h5 style="margin-top:25px">
            <strong>Hardware lifecycle</strong>
            <a href="{{ $ui_page_url }}?rescan=hw" class="btn btn-default btn-sm" style="margin-left:10px">Rescan hardware</a>
            @if($ui_todo_hw > 0)<span style="color:#f0ad4e;margin-left:10px">{{ $ui_todo_hw }} to complete</span>@endif
        </h5>
        @if($ui_rescan === 'hw' || $ui_rescan === 'all')
            <p style="color:#5bc0de">Rescan done and saved: new PIDs are highlighted (status "To complete").</p>
        @endif
        <table class="table table-condensed table-hover" style="font-size:12px">
            <thead>
            <tr>
                <th>PID prefix</th><th>Devices</th><th>Status</th><th>End-of-Sale</th><th>End of security</th>
                <th>Last Date of Support</th><th>Bulletin URL</th><th>Checked</th><th>Find</th><th>Remove</th>
            </tr>
            </thead>
            <tbody>
            @foreach($ui_hw_rows as $i => $r)
                <tr @if(!empty($r['new'])) style="background:#fcf8e3" @elseif($r['devices'] === 0) style="color:#aaaaaa" @endif>
                    <td><input type="text" class="form-control input-sm" name="settings[hw_rows][{{ $i }}][key]" value="{{ $r['key'] }}" style="min-width:150px"></td>
                    <td title="{{ implode(', ', $r['pids']) }}">{{ $r['devices'] }}</td>
                    <td>
                        <select class="form-control input-sm ciscoeox-status" name="settings[hw_rows][{{ $i }}][status]">
                            @foreach($statusLabels as $k => $lbl)
                                <option value="{{ $k }}" @if($r['status'] === $k) selected @endif>{{ $lbl }}</option>
                            @endforeach
                        </select>
                    </td>
                    <td><input type="date" class="form-control input-sm" name="settings[hw_rows][{{ $i }}][d1]" value="{{ $r['d1'] }}"></td>
                    <td><input type="date" class="form-control input-sm" name="settings[hw_rows][{{ $i }}][d2]" value="{{ $r['d2'] }}"></td>
                    <td><input type="date" class="form-control input-sm" name="settings[hw_rows][{{ $i }}][d3]" value="{{ $r['d3'] }}"></td>
                    <td><input type="text" class="form-control input-sm" name="settings[hw_rows][{{ $i }}][url]" value="{{ $r['url'] }}" style="min-width:200px"></td>
                    <td><input type="date" class="form-control input-sm ciscoeox-checked" name="settings[hw_rows][{{ $i }}][checked]" value="{{ $r['checked'] }}"></td>
                    <td><a href="{{ $r['lookup'] }}" target="_blank" rel="noopener">Search</a></td>
                    <td style="text-align:center"><input type="checkbox" name="settings[hw_rows][{{ $i }}][remove]" value="1"></td>
                </tr>
            @endforeach
            </tbody>
        </table>

        {{-- ===== Software ===== --}}
        <h5 style="margin-top:25px">
            <strong>Software lifecycle</strong>
            <a href="{{ $ui_page_url }}?rescan=sw" class="btn btn-default btn-sm" style="margin-left:10px">Rescan IOS</a>
            @if($ui_todo_sw > 0)<span style="color:#f0ad4e;margin-left:10px">{{ $ui_todo_sw }} to complete</span>@endif
        </h5>
        @if($ui_rescan === 'sw' || $ui_rescan === 'all')
            <p style="color:#5bc0de">Rescan done and saved: new release trains are highlighted (status "To complete").</p>
        @endif
        <table class="table table-condensed table-hover" style="font-size:12px">
            <thead>
            <tr>
                <th>OS</th><th>Train</th><th>Devices</th><th>Status</th><th>End of SW maint.</th><th>End of security</th>
                <th>Last Date of Support</th><th>Bulletin URL</th><th>Checked</th><th>Find</th><th>Remove</th>
            </tr>
            </thead>
            <tbody>
            @foreach($ui_sw_rows as $i => $r)
                <tr @if(!empty($r['new'])) style="background:#fcf8e3" @elseif($r['devices'] === 0) style="color:#aaaaaa" @endif>
                    <td><input type="text" class="form-control input-sm" name="settings[sw_rows][{{ $i }}][os]" value="{{ $r['os'] }}" style="width:70px"></td>
                    <td><input type="text" class="form-control input-sm" name="settings[sw_rows][{{ $i }}][key]" value="{{ $r['key'] }}" style="min-width:110px"></td>
                    <td title="{{ implode(', ', $r['versions']) }}">{{ $r['devices'] }}</td>
                    <td>
                        <select class="form-control input-sm ciscoeox-status" name="settings[sw_rows][{{ $i }}][status]">
                            @foreach($statusLabels as $k => $lbl)
                                <option value="{{ $k }}" @if($r['status'] === $k) selected @endif>{{ $lbl }}</option>
                            @endforeach
                        </select>
                    </td>
                    <td><input type="date" class="form-control input-sm" name="settings[sw_rows][{{ $i }}][d1]" value="{{ $r['d1'] }}"></td>
                    <td><input type="date" class="form-control input-sm" name="settings[sw_rows][{{ $i }}][d2]" value="{{ $r['d2'] }}"></td>
                    <td><input type="date" class="form-control input-sm" name="settings[sw_rows][{{ $i }}][d3]" value="{{ $r['d3'] }}"></td>
                    <td><input type="text" class="form-control input-sm" name="settings[sw_rows][{{ $i }}][url]" value="{{ $r['url'] }}" style="min-width:200px"></td>
                    <td><input type="date" class="form-control input-sm ciscoeox-checked" name="settings[sw_rows][{{ $i }}][checked]" value="{{ $r['checked'] }}"></td>
                    <td><a href="{{ $r['lookup'] }}" target="_blank" rel="noopener">Search</a></td>
                    <td style="text-align:center"><input type="checkbox" name="settings[sw_rows][{{ $i }}][remove]" value="1"></td>
                </tr>
            @endforeach
            </tbody>
        </table>
        <p style="color:#777777">Grey rows: no device currently matches (kept until removed). "Search" opens a web search restricted to cisco.com EoL bulletins.</p>

        <h5 style="margin-top:25px"><strong>Disabled advisories</strong> (set from each device page)</h5>
        <p>Global: {{ count($ui_na_global) }} - Local: {{ $ui_na_local_count }}</p>
        @if(count($ui_na_global) > 0)
            <table class="table table-condensed" style="max-width:900px;font-size:12px">
                <tr><th>Advisory (Global)</th><th>By</th><th>Date</th></tr>
                @foreach($ui_na_global as $adv => $info)
                    <tr><td>{{ $adv }}</td><td>{{ $info['user'] ?? '' }}</td><td>{{ $info['date'] ?? '' }}</td></tr>
                @endforeach
            </table>
        @endif
        {{-- kept as-is on save, edited from device pages --}}
        <input type="hidden" name="settings[na]" value="{{ $ui_na_json }}">

        <div style="margin-top:20px">
            <button type="submit" class="btn btn-primary">Save</button>
        </div>
    </form>
</div>
<script>
    (function () {
        // remove one-shot parameters (refresh / rescan) from the address bar
        if (/[?&](refresh|rescan)=/.test(window.location.search) && window.history.replaceState) {
            window.history.replaceState(null, '', window.location.pathname);
        }
        // fill "Checked" with today when the status is changed and the field is empty
        document.querySelectorAll('#ciscoeox-settings .ciscoeox-status').forEach(function (sel) {
            sel.addEventListener('change', function () {
                var row = sel.closest('tr');
                var checked = row ? row.querySelector('.ciscoeox-checked') : null;
                if (checked && checked.value === '' && sel.value !== 'todo') {
                    checked.value = new Date().toISOString().slice(0, 10);
                }
            });
        });
    })();
</script>
EOF_CISCOEOX_4
cat > "${PLUGIN_DIR}/bin/refresh.php" <<'EOF_CISCOEOX_5'
<?php

/*
 * CiscoEox - background refresh of the Cisco PSIRT advisories cache.
 * Fetches advisories for every distinct (os, version) of the enabled Cisco devices,
 * so that device pages never wait for the Cisco API.
 *
 * Run as librenms (cron: /etc/cron.d/librenms-ciscoeox):
 *   php /opt/librenms/app/Plugins/CiscoEox/bin/refresh.php
 */

$base = dirname(__DIR__, 4); // /opt/librenms
require $base . '/vendor/autoload.php';
$app = require $base . '/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

use App\Plugins\CiscoEox\Lib\Eox;

$raw = \App\Models\Plugin::where('plugin_name', Eox::PLUGIN)->value('settings');
$settings = is_array($raw) ? $raw : (is_string($raw) ? (array) json_decode($raw, true) : []);
if (trim((string) ($settings['client_id'] ?? '')) === '') {
    echo date('Y-m-d H:i') . " CiscoEox: Cisco API credentials not set, nothing done\n";
    exit(0);
}

$devices = \App\Models\Device::query()
    ->where('disabled', 0)
    ->whereIn('os', array_keys(Eox::OS_MAP))
    ->get(['os', 'version'])
    ->map(fn ($d) => ['os' => $d->os, 'version' => $d->version])
    ->all();

$report = Eox::refresh($settings, $devices);
echo $report['date'] . ' CiscoEox refresh: OK ' . $report['ok'] . ' / failed ' . $report['failed'] . ' (' . $report['seconds'] . " s)\n";
foreach ($report['details'] as $line) {
    echo '  ' . $line . "\n";
}
exit($report['failed'] > 0 ? 1 : 0);
EOF_CISCOEOX_5

chown -R librenms:librenms "${PLUGIN_DIR}"
find "${PLUGIN_DIR}" -type d -exec chmod 755 {} +
find "${PLUGIN_DIR}" -type f -exec chmod 644 {} +

# syntax check of the PHP files
for f in "${PLUGIN_DIR}/Lib/Eox.php" "${PLUGIN_DIR}/DeviceOverview.php" "${PLUGIN_DIR}/Settings.php" "${PLUGIN_DIR}/bin/refresh.php"; do
    php -l "$f" >/dev/null || { echo "ERROR: syntax error in $f"; exit 1; }
done

# background refresh of the advisories cache, every 6 hours
cat > "${CRON_FILE}" <<'EOF_CISCOEOX_CRON'
# CiscoEox: refresh Cisco PSIRT advisories cache (device pages read the cache only)
23 */6 * * * librenms php /opt/librenms/app/Plugins/CiscoEox/bin/refresh.php >> /opt/librenms/logs/ciscoeox.log 2>&1
EOF_CISCOEOX_CRON
chmod 644 "${CRON_FILE}"
chown root:root "${CRON_FILE}"

sudo -u librenms php "${LNMS_DIR}/artisan" view:clear >/dev/null

echo "OK - CiscoEox installed in ${PLUGIN_DIR}, cron in ${CRON_FILE}"
echo "First refresh of the advisories cache (may take about 30 s):"
sudo -u librenms timeout 300 php "${PLUGIN_DIR}/bin/refresh.php" || echo "WARNING: refresh reported errors (see above)"
