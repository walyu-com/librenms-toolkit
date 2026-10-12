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
