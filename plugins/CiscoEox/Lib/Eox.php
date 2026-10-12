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
