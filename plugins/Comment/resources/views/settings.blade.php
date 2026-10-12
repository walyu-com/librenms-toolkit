<div style="margin: 15px; max-width: 700px;">
    <h4>Comment settings</h4>
    <form method="post">
        @csrf
        <table class="table table-condensed">
            <tr>
                <td style="width:260px">Visible lines in the device box</td>
                <td>
                    <input type="number" min="0" max="200" class="form-control" name="settings[visible_lines]" value="{{ $ui_visible_lines }}">
                    <span style="color:#777777;font-size:12px">0 = no limit (whole text). Longer notes get a scroll bar.</span>
                </td>
            </tr>
            <tr>
                <td>Editor rows ([EDIT])</td>
                <td><input type="number" min="3" max="100" class="form-control" name="settings[editor_rows]" value="{{ $ui_editor_rows }}"></td>
            </tr>
            <tr>
                <td>Common first line</td>
                <td>
                    <textarea class="form-control" name="settings[common_first_line]" rows="4" style="font-family:monospace;font-size:13px">{{ $ui_common_first_line }}</textarea>
                    <span style="color:#777777;font-size:12px">Shown on top of the notes of every device. Simple HTML (&lt;a href&gt;, &lt;b&gt;, ...) and Markdown allowed.
                    Placeholders replaced per device: {ip} {sysname} {name} {id}.
                    Example: &lt;a href="http://&lt;server&gt;:8090/?ip={ip}"&gt;NetCmd&lt;/a&gt;</span>
                </td>
            </tr>
        </table>
        <button type="submit" class="btn btn-primary">Save</button>
    </form>
</div>
