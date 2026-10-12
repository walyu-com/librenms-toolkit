#!/usr/bin/env bash
# install-comment.sh - installs or updates the "Comment" local plugin for LibreNMS
# (device notes with Markdown, simple HTML, line breaks and an inline editor)
# Usage: sudo bash install-comment.sh
set -euo pipefail

LNMS_DIR="/opt/librenms"
PLUGIN_DIR="${LNMS_DIR}/app/Plugins/Comment"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash install-comment.sh)"
    exit 1
fi
if [ ! -d "${LNMS_DIR}/app/Plugins" ]; then
    echo "ERROR: ${LNMS_DIR}/app/Plugins not found"
    exit 1
fi

if [ -d "${PLUGIN_DIR}" ]; then
    BACKUP="/root/Comment.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${PLUGIN_DIR}" "${BACKUP}"
    echo "Existing plugin saved to ${BACKUP}"
fi

mkdir -p "${PLUGIN_DIR}/Lib" "${PLUGIN_DIR}/resources/views"
cat > "${PLUGIN_DIR}/Lib/Notes.php" <<'EOF_COMMENT_0'
<?php

/*
 * Comment - LibreNMS local plugin
 * Helper: renders device notes (Markdown + simple HTML + line breaks) and sanitizes the result.
 * Lives in a sub folder on purpose: every *.php directly in app/Plugins/Comment/ must be a hook.
 */

namespace App\Plugins\Comment\Lib;

use Illuminate\Support\Str;

class Notes
{
    // tags kept as-is (all attributes removed, except href on <a>)
    public const ALLOWED = [
        'b', 'strong', 'i', 'em', 'u', 's', 'br', 'p', 'div', 'span', 'hr',
        'ul', 'ol', 'li', 'a', 'code', 'pre', 'blockquote',
        'h3', 'h4', 'h5', 'h6', 'table', 'thead', 'tbody', 'tr', 'th', 'td',
    ];

    // tags removed together with their content
    public const DROP = ['script', 'style', 'iframe', 'object', 'embed', 'form', 'input', 'button', 'textarea', 'select', 'link', 'meta', 'svg', 'math'];

    /**
     * Markdown (with soft line breaks rendered as <br>) + simple HTML, then sanitized.
     */
    public static function render(?string $notes): string
    {
        $notes = (string) $notes;
        if (trim($notes) === '') {
            return '';
        }
        $html = Str::markdown($notes, [
            'html_input' => 'allow',
            'allow_unsafe_links' => false,
            'renderer' => ['soft_break' => "<br>\n"],
        ]);

        return self::sanitize($html);
    }

    public static function sanitize(string $html): string
    {
        $doc = new \DOMDocument();
        $previous = libxml_use_internal_errors(true);
        $doc->loadHTML('<?xml encoding="UTF-8"><div>' . $html . '</div>', LIBXML_HTML_NOIMPLIED | LIBXML_HTML_NODEFDTD);
        libxml_clear_errors();
        libxml_use_internal_errors($previous);

        $root = null;
        foreach ($doc->childNodes as $node) {
            if ($node instanceof \DOMElement) {
                $root = $node;
                break;
            }
        }
        if ($root === null) {
            return '';
        }
        self::clean($root);

        $out = '';
        foreach ($root->childNodes as $child) {
            $out .= $doc->saveHTML($child);
        }

        return $out;
    }

    protected static function clean(\DOMNode $node): void
    {
        // iterate on a copy: the list changes while nodes are removed or unwrapped
        foreach (iterator_to_array($node->childNodes) as $child) {
            if ($child instanceof \DOMComment || $child instanceof \DOMProcessingInstruction) {
                $node->removeChild($child);
                continue;
            }
            if (! $child instanceof \DOMElement) {
                continue;
            }
            $tag = strtolower($child->nodeName);
            if (in_array($tag, self::DROP, true)) {
                $node->removeChild($child);
                continue;
            }
            self::clean($child);
            if (! in_array($tag, self::ALLOWED, true)) {
                // unknown tag: keep its content, drop the tag
                while ($child->firstChild) {
                    $node->insertBefore($child->firstChild, $child);
                }
                $node->removeChild($child);
                continue;
            }
            $href = $tag === 'a' ? trim($child->getAttribute('href')) : '';
            foreach (iterator_to_array($child->attributes) as $attr) {
                $child->removeAttribute($attr->nodeName);
            }
            if ($tag === 'a') {
                if (preg_match('#^(https?://|mailto:)#i', $href)) {
                    $child->setAttribute('href', $href);
                    $child->setAttribute('target', '_blank');
                    $child->setAttribute('rel', 'noopener');
                }
            }
        }
    }
}
EOF_COMMENT_0
cat > "${PLUGIN_DIR}/DeviceOverview.php" <<'EOF_COMMENT_1'
<?php

/*
 * Comment - LibreNMS local plugin
 * Device overview box: device notes rendered with Markdown, simple HTML and line breaks,
 * with an inline editor (saved through the standard LibreNMS notes route).
 */

namespace App\Plugins\Comment;

use App\Models\Device;
use App\Models\User;
use App\Plugins\Comment\Lib\Notes;
use App\Plugins\Hooks\DeviceOverviewHook;

class DeviceOverview extends DeviceOverviewHook
{
    public function authorize(User $user, Device $device): bool
    {
        return true;
    }

    public function data(Device $device, array $settings = []): array
    {
        $user = auth()->user();

        return [
            'title' => 'Comment Plugin: Device Notes',
            'device' => $device,
            'html' => Notes::render($device->notes),
            'commonHtml' => Notes::render(Settings::commonFirstLine($settings, $device)),
            'raw' => (string) $device->notes,
            'canEdit' => $user !== null && $user->can('updateNotes', $device),
            'updateUrl' => route('device.notes.update', $device),
            'visibleLines' => Settings::visibleLines($settings),
            'editorRows' => Settings::editorRows($settings),
        ];
    }
}
EOF_COMMENT_1
cat > "${PLUGIN_DIR}/Menu.php" <<'EOF_COMMENT_2'
<?php

/*
 * Comment - LibreNMS local plugin
 * Entry "Comment" in Overview > Plugins: list of all devices having notes.
 */

namespace App\Plugins\Comment;

use App\Models\User;
use App\Plugins\Hooks\MenuEntryHook;

class Menu extends MenuEntryHook
{
    public function authorize(User $user): bool
    {
        return $user->can('global-read');
    }
}
EOF_COMMENT_2
cat > "${PLUGIN_DIR}/Page.php" <<'EOF_COMMENT_3'
<?php

/*
 * Comment - LibreNMS local plugin
 * Page: every device with notes (Overview > Plugins > Comment).
 */

namespace App\Plugins\Comment;

use App\Models\Device;
use App\Models\User;
use App\Plugins\Comment\Lib\Notes;
use App\Plugins\Hooks\PageHook;

class Page extends PageHook
{
    public function authorize(User $user): bool
    {
        return $user->can('global-read');
    }

    public function data(): array
    {
        $rows = [];
        $devices = Device::query()
            ->whereNotNull('notes')
            ->where('notes', '!=', '')
            ->get();
        foreach ($devices as $device) {
            $rows[] = [
                'name' => $device->displayName(),
                'ip' => (string) $device->hostname,
                'url' => url('device/' . $device->device_id),
                'html' => Notes::render($device->notes),
            ];
        }
        usort($rows, fn ($a, $b) => strnatcasecmp($a['name'], $b['name']));

        return [
            'title' => 'Comment: devices with notes',
            'rows' => $rows,
        ];
    }
}
EOF_COMMENT_3
cat > "${PLUGIN_DIR}/resources/views/device-overview.blade.php" <<'EOF_COMMENT_4'
<div class="tw:mb-5 tw:rounded-lg tw:border tw:border-gray-300 tw:shadow-sm tw:dark:border-dark-gray-200" id="comment-plugin">
    <div class="tw:px-4 tw:py-2.5 tw:bg-neutral-100 tw:border-b tw:border-gray-300 tw:text-neutral-700 tw:dark:bg-dark-gray-200 tw:dark:border-zinc-800 tw:dark:text-dark-white-200">
        <strong>{{ $title }}</strong>
        @if($canEdit)
            <a href="#" id="comment-edit-toggle" style="margin-left:10px">[EDIT]</a>
        @endif
    </div>
    <div class="tw:px-4 tw:py-2 tw:bg-white tw:dark:bg-dark-gray-400">
        @if($commonHtml !== '')
            <div class="comment-notes comment-common" style="font-size:14px;line-height:1.5em;padding-bottom:4px;margin-bottom:6px;border-bottom:1px solid #dddddd">{!! $commonHtml !!}</div>
        @endif
        <div id="comment-view" class="comment-notes" style="font-size:14px;line-height:1.5em;@if($visibleLines > 0) height:{{ $visibleLines * 1.5 }}em;overflow-y:auto;@endif">
            @if($html !== '')
                {!! $html !!}
            @else
                <span style="color:#999999">No notes for this device.</span>
            @endif
        </div>
        @if($canEdit)
            <form id="comment-form" method="post" action="{{ $updateUrl }}" style="display:none">
                @csrf
                @method('PUT')
                <textarea class="form-control" name="note" rows="{{ $editorRows }}" style="font-family:monospace;font-size:13px">{{ $raw }}</textarea>
                <div style="margin-top:6px;color:#777777;font-size:12px">
                    Line breaks are kept. Simple HTML allowed: &lt;b&gt; &lt;i&gt; &lt;u&gt; &lt;br&gt; &lt;ul&gt;&lt;li&gt; &lt;a href&gt; &lt;table&gt; ... and Markdown (**bold**, *italic*, - list).
                </div>
                <div style="margin-top:6px">
                    <button type="submit" class="btn btn-primary btn-sm"><i class="fa fa-check"></i> Save</button>
                    <button type="button" class="btn btn-default btn-sm" id="comment-cancel">Cancel</button>
                </div>
            </form>
        @endif
    </div>
</div>
<style>
    #comment-plugin .comment-notes p { margin: 0 0 6px 0; }
    #comment-plugin .comment-notes table td, #comment-plugin .comment-notes table th { border: 1px solid #cccccc; padding: 2px 6px; }
</style>
@if($canEdit)
<script>
    (function () {
        var view = document.getElementById('comment-view');
        var form = document.getElementById('comment-form');
        function toggle(edit) {
            view.style.display = edit ? 'none' : '';
            form.style.display = edit ? '' : 'none';
            if (edit) { form.querySelector('textarea').focus(); }
        }
        document.getElementById('comment-edit-toggle').addEventListener('click', function (e) {
            e.preventDefault();
            toggle(form.style.display === 'none');
        });
        document.getElementById('comment-cancel').addEventListener('click', function () { toggle(false); });
    })();
</script>
@endif
EOF_COMMENT_4
cat > "${PLUGIN_DIR}/resources/views/menu.blade.php" <<'EOF_COMMENT_5'
<a href="{{ url('plugin/Comment') }}"><i class="fa fa-comment fa-fw fa-lg" aria-hidden="true"></i> Comment</a>
EOF_COMMENT_5
cat > "${PLUGIN_DIR}/resources/views/page.blade.php" <<'EOF_COMMENT_6'
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
EOF_COMMENT_6
cat > "${PLUGIN_DIR}/Settings.php" <<'EOF_COMMENT_7'
<?php

/*
 * Comment - LibreNMS local plugin
 * Settings page: Overview > Plugins > Plugin Admin > Comment > Settings
 */

namespace App\Plugins\Comment;

use App\Plugins\Hooks\SettingsHook;

class Settings extends SettingsHook
{
    public const DEFAULT_VISIBLE_LINES = 6;

    public const DEFAULT_EDITOR_ROWS = 12;

    public static function visibleLines(array $settings): int
    {
        $n = (int) ($settings['visible_lines'] ?? self::DEFAULT_VISIBLE_LINES);

        return max(0, min(200, $n));
    }

    public static function editorRows(array $settings): int
    {
        $n = (int) ($settings['editor_rows'] ?? self::DEFAULT_EDITOR_ROWS);

        return max(3, min(100, $n));
    }

    /**
     * "Common first line" shown on top of every device note box.
     * Placeholders replaced per device: {ip} {sysname} {name} {id}
     */
    public static function commonFirstLine(array $settings, \App\Models\Device $device): string
    {
        $text = (string) ($settings['common_first_line'] ?? '');
        if (trim($text) === '') {
            return '';
        }
        $h = fn ($v) => htmlspecialchars((string) $v, ENT_QUOTES, 'UTF-8');

        return strtr($text, [
            '{ip}' => $h($device->hostname),
            '{sysname}' => $h($device->sysName),
            '{name}' => $h($device->displayName()),
            '{id}' => $h($device->device_id),
        ]);
    }

    public function data(array $settings): array
    {
        // view variables prefixed ui_: LibreNMS also spreads the stored settings into the view
        return [
            'settings' => $settings,
            'ui_visible_lines' => self::visibleLines($settings),
            'ui_editor_rows' => self::editorRows($settings),
            'ui_common_first_line' => (string) ($settings['common_first_line'] ?? ''),
        ];
    }
}
EOF_COMMENT_7
cat > "${PLUGIN_DIR}/resources/views/settings.blade.php" <<'EOF_COMMENT_8'
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
EOF_COMMENT_8

chown -R librenms:librenms "${PLUGIN_DIR}"
find "${PLUGIN_DIR}" -type d -exec chmod 755 {} +
find "${PLUGIN_DIR}" -type f -exec chmod 644 {} +

for f in "${PLUGIN_DIR}/Lib/Notes.php" "${PLUGIN_DIR}/DeviceOverview.php" "${PLUGIN_DIR}/Menu.php" "${PLUGIN_DIR}/Page.php" "${PLUGIN_DIR}/Settings.php"; do
    php -l "$f" >/dev/null || { echo "ERROR: syntax error in $f"; exit 1; }
done

sudo -u librenms php "${LNMS_DIR}/artisan" view:clear >/dev/null

echo "OK - Comment plugin installed in ${PLUGIN_DIR}"
echo "Next: Overview > Plugins > Plugin Admin: disable ExamplePlugin (Comment replaces it)"
