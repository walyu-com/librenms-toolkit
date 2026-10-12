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
