<?php

/*
 * Netcmd - LibreNMS local plugin
 * Entry "netcmd" in Overview > Plugins (opens netcmd in a new tab).
 */

namespace App\Plugins\Netcmd;

use App\Models\User;
use App\Plugins\Hooks\MenuEntryHook;

class Menu extends MenuEntryHook
{
    public function authorize(User $user): bool
    {
        return $user->can('global-read');
    }

    public function data(array $settings = []): array
    {
        return ['url' => Settings::baseUrl($settings) . '/'];
    }
}
