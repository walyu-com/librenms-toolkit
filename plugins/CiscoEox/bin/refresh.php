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
