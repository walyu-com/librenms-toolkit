<div style="margin: 15px; max-width: 700px;">
    <h4>Netcmd settings</h4>
    <form method="post">
        @csrf
        <table class="table table-condensed">
            <tr>
                <td style="width:180px">netcmd URL</td>
                <td>
                    <input type="text" class="form-control" name="settings[url]" value="{{ $ui_url }}" placeholder="{{ $ui_default }}">
                    <span style="color:#777777;font-size:12px">Empty = {{ $ui_default }} (same host as LibreNMS, port 8090)</span>
                </td>
            </tr>
        </table>
        <button type="submit" class="btn btn-primary">Save</button>
    </form>
</div>
