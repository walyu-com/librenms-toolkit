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
