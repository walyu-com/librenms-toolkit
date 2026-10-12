<div style="margin: 15px;">
    <h4>{{ $title }}</h4>
    @if(count($rows) === 0)
        <p style="color:#999999">No device has notes.</p>
    @else
        <table class="table table-condensed table-hover" id="comment-page">
            <thead>
                <tr><th style="width:250px">Device</th><th style="width:140px">Hostname / IP</th><th>Notes</th></tr>
            </thead>
            <tbody>
            @foreach($rows as $r)
                <tr>
                    <td><a href="{{ $r['url'] }}">{{ $r['name'] }}</a></td>
                    <td>{{ $r['ip'] }}</td>
                    <td class="comment-notes">{!! $r['html'] !!}</td>
                </tr>
            @endforeach
            </tbody>
        </table>
    @endif
</div>
<style>
    #comment-page .comment-notes p { margin: 0 0 4px 0; }
</style>
