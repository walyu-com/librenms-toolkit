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
