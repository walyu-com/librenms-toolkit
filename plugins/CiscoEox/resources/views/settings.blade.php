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
