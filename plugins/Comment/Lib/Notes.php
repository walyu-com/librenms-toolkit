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
