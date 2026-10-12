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
