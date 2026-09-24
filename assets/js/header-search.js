import * as params from '@params';

/* 헤더 검색창: 입력하는 동안 결과를 최대 5개까지 바로 아래에 보여 준다.
   Fuse.js와 index.json은 입력창에 처음 포커스할 때 불러온다. */

const form = document.querySelector('.hsearch');
const input = document.getElementById('hsearch-input');
const drop = document.getElementById('hsearch-results');
const LIMIT = 5;

let fuse = null;
let loading = null;
let items = [];
let active = -1;

const fuseOptions = () => {
    const o = params.fuseOpts || {};
    return {
        keys: o.keys || ['title', 'summary', 'content'],
        threshold: o.threshold ?? 0.4,
        ignoreLocation: o.ignorelocation ?? true,
        minMatchCharLength: o.minmatchcharlength ?? 1
    };
};

const loadScript = (src) => new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.onload = resolve;
    s.onerror = reject;
    document.head.appendChild(s);
});

const load = () => {
    if (!loading) {
        loading = Promise.all([
            window.Fuse ? null : loadScript(form.dataset.fuse),
            fetch(form.dataset.index).then((r) => {
                if (!r.ok) throw new Error(`search index ${r.status}`);
                return r.json();
            })
        ]).then(([, data]) => {
            fuse = new window.Fuse(data, fuseOptions());
            search();
        }).catch((e) => {
            loading = null;
            console.error(e);
        });
    }
    return loading;
};

/* 제목에서 검색어와 같은 부분을 강조색으로 표시 (대소문자 무시) */
const highlight = (el, text, q) => {
    const i = text.toLowerCase().indexOf(q.toLowerCase());
    if (!q || i < 0) {
        el.textContent = text;
        return;
    }
    const mark = document.createElement('mark');
    mark.textContent = text.slice(i, i + q.length);
    el.append(text.slice(0, i), mark, text.slice(i + q.length));
};

const allResultsUrl = (q) => `${form.action}?q=${encodeURIComponent(q)}`;

const setActive = (i) => {
    items.forEach((a, n) => a.classList.toggle('is-active', n === i));
    active = i;
    if (i >= 0) {
        input.setAttribute('aria-activedescendant', items[i].id);
        items[i].scrollIntoView({ block: 'nearest' });
    } else {
        input.removeAttribute('aria-activedescendant');
    }
};

const open = (show) => {
    drop.hidden = !show;
    input.setAttribute('aria-expanded', String(show));
    if (!show) setActive(-1);
};

const render = (q, results) => {
    drop.textContent = '';
    items = [];

    if (!results.length) {
        const empty = document.createElement('p');
        empty.className = 'hsearch-empty';
        empty.textContent = `"${q}"에 맞는 글이 없습니다`;
        drop.appendChild(empty);
    }

    results.slice(0, LIMIT).forEach(({ item }) => {
        const a = document.createElement('a');
        a.href = item.permalink;
        const b = document.createElement('b');
        highlight(b, item.title, q);
        a.appendChild(b);
        if (item.summary) {
            const small = document.createElement('small');
            small.textContent = item.summary;
            a.appendChild(small);
        }
        items.push(a);
    });

    if (results.length > LIMIT) {
        const more = document.createElement('a');
        more.className = 'hsearch-more';
        more.href = allResultsUrl(q);
        more.textContent = `"${q}" 모든 결과 보기 (${results.length})`;
        items.push(more);
    }

    items.forEach((a, n) => {
        a.id = `hsearch-opt-${n}`;
        a.setAttribute('role', 'option');
        drop.appendChild(a);
    });
    setActive(-1);
    open(true);
};

const search = () => {
    const q = input.value.trim();
    if (!q) {
        open(false);
        return;
    }
    if (!fuse) {
        load();
        return;
    }
    render(q, fuse.search(q));
};

let timer;
if (form && input && drop) {
    input.addEventListener('focus', load, { once: true });
    input.addEventListener('focus', () => { if (input.value.trim() && fuse) search(); });
    input.addEventListener('input', () => {
        clearTimeout(timer);
        timer = setTimeout(search, 120);
    });

    input.addEventListener('keydown', (e) => {
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
            if (drop.hidden || !items.length) return;
            e.preventDefault();
            const step = e.key === 'ArrowDown' ? 1 : -1;
            const next = active + step;
            setActive(next < -1 ? items.length - 1 : next >= items.length ? -1 : next);
        } else if (e.key === 'Enter') {
            if (active >= 0) {
                e.preventDefault();
                window.location.href = items[active].href;
            } else if (!input.value.trim()) {
                e.preventDefault();
            }
            /* 고른 항목이 없으면 form 제출로 검색 페이지(/search/?q=)로 간다 */
        } else if (e.key === 'Escape') {
            if (!drop.hidden) {
                open(false);
            } else {
                input.value = '';
                input.blur();
            }
        }
    });

    /* 결과를 누를 때 입력창 blur로 목록이 먼저 닫히지 않게 한다 */
    drop.addEventListener('mousedown', (e) => e.preventDefault());

    document.addEventListener('click', (e) => {
        if (!form.contains(e.target)) open(false);
    });

    /* 어느 화면에서든 / 키로 입력창에 포커스 */
    document.addEventListener('keydown', (e) => {
        if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey) return;
        const t = e.target;
        if (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)) return;
        e.preventDefault();
        input.focus();
        input.select();
    });
}
