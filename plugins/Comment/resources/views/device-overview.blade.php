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
