'use strict';
'require view';
'require rpc';
'require poll';
'require dom';

var callGetStatus = rpc.declare({
    object: 'luci.dae',
    method: 'getInitStatus',
    expect: { '': {} }
});

return L.Class.extend({
    __init__: function() {
        this.logEl = null;
        this.filterInput = null;
        this.paused = false;
        this.currentFilter = '';
        this.debounceTimer = null;
        this.logContent = '';
        this.MAX_LINES = 500;
    },

    _injectStyles: function() {
        if (document.getElementById('dae-log-styles')) return;

        var css = `
            .dae-log-container {
                position: relative;
                border: 1px solid #ddd;
                border-radius: 4px;
                overflow: hidden;
            }
            .dae-log-toolbar {
                display: flex;
                gap: 6px;
                padding: 8px;
                background: #f5f5f5;
                border-bottom: 1px solid #ddd;
                align-items: center;
                flex-wrap: wrap;
            }
            .dae-log-toolbar input {
                flex: 1;
                min-width: 150px;
                padding: 4px 8px;
                border: 1px solid #ccc;
                border-radius: 3px;
                font-size: 13px;
            }
            .dae-log-toolbar button {
                padding: 4px 10px;
                border: 1px solid #ccc;
                border-radius: 3px;
                background: #fff;
                cursor: pointer;
                font-size: 12px;
                white-space: nowrap;
            }
            .dae-log-toolbar button:hover {
                background: #e8e8e8;
            }
            .dae-log-toolbar button.active {
                background: #ff9800;
                color: #fff;
                border-color: #f57c00;
            }
            .dae-log-viewer {
                height: 400px;
                overflow-y: auto;
                padding: 8px 12px;
                background: #fafafa;
                font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
                font-size: 12px;
                line-height: 1.6;
                white-space: pre-wrap;
                word-break: break-all;
                color: #333;
            }
            .dae-log-line {
                padding: 1px 0;
            }
            .dae-log-line.level-info {
                color: #1976d2;
            }
            .dae-log-line.level-warn {
                color: #f57c00;
            }
            .dae-log-line.level-error {
                color: #d32f2f;
            }
            .dae-log-line.level-debug {
                color: #7b1fa2;
            }
            .dae-log-line .dae-ip {
                color: #00897b;
                font-weight: bold;
            }
            .dae-log-line .dae-filter-match {
                background: #fff176;
                padding: 0 2px;
                border-radius: 2px;
            }
            @media (prefers-color-scheme: dark) {
                .dae-log-viewer {
                    background: #1e1e1e;
                    color: #d4d4d4;
                    border-color: #444;
                }
                .dae-log-toolbar {
                    background: #2d2d2d;
                    border-color: #444;
                }
                .dae-log-toolbar input {
                    background: #3c3c3c;
                    color: #d4d4d4;
                    border-color: #555;
                }
                .dae-log-toolbar button {
                    background: #3c3c3c;
                    color: #d4d4d4;
                    border-color: #555;
                }
                .dae-log-toolbar button:hover {
                    background: #4a4a4a;
                }
                .dae-log-line.level-info {
                    color: #64b5f6;
                }
                .dae-log-line.level-warn {
                    color: #ffb74d;
                }
                .dae-log-line.level-error {
                    color: #ef5350;
                }
                .dae-log-line.level-debug {
                    color: #ce93d8;
                }
                .dae-log-line .dae-ip {
                    color: #80cbc4;
                }
                .dae-log-line .dae-filter-match {
                    background: #f9a825;
                    color: #000;
                }
            }
        `;

        var style = document.createElement('style');
        style.id = 'dae-log-styles';
        style.textContent = css;
        document.head.appendChild(style);
    },

    render: function(targetEl) {
        var self = this;

        this._injectStyles();

        var container = E('div', { 'class': 'dae-log-container' });

        // Toolbar
        var toolbar = E('div', { 'class': 'dae-log-toolbar' });

        // Filter input with debounce
        this.filterInput = E('input', {
            'type': 'text',
            'placeholder': _('Filter logs...'),
            'style': 'flex: 1;',
        });
        this.filterInput.addEventListener('input', function(e) {
            clearTimeout(self.debounceTimer);
            self.debounceTimer = setTimeout(function() {
                self.currentFilter = e.target.value.toLowerCase();
                self._applyFilter();
            }, 200);
        });

        // Pause/Resume button
        this.pauseBtn = E('button', { 'click': function() { self._togglePause(); } },
            _('Pause'));
        this.pauseBtn.title = _('Pause/Resume auto-refresh');

        // Clear button
        var clearBtn = E('button', { 'click': function() { self._clearLog(); } },
            _('Clear'));

        // Scroll buttons
        var scrollUpBtn = E('button', { 'click': function() { self._scrollUp(); } }, '↑');
        scrollUpBtn.title = _('Scroll to top');
        var scrollDownBtn = E('button', { 'click': function() { self._scrollDown(); } }, '↓');
        scrollDownBtn.title = _('Scroll to bottom');

        // Line count
        this.lineCountEl = E('span', { 'style': 'color: #999; font-size: 11px; white-space: nowrap;' });

        toolbar.appendChild(this.filterInput);
        toolbar.appendChild(this.pauseBtn);
        toolbar.appendChild(clearBtn);
        toolbar.appendChild(scrollUpBtn);
        toolbar.appendChild(scrollDownBtn);
        toolbar.appendChild(this.lineCountEl);

        // Log viewer
        this.logEl = E('div', { 'class': 'dae-log-viewer' },
            E('div', { 'class': 'dae-log-line' }, _('Waiting for log data...'))
        );

        container.appendChild(toolbar);
        container.appendChild(this.logEl);

        targetEl.appendChild(container);

        // Start polling log
        this._startPolling();
    },

    _startPolling: function() {
        var self = this;

        poll.add(function() {
            if (self.paused) return Promise.resolve();

            return callGetStatus().then(function(data) {
                if (!data.running) {
                    self._appendLog('[dae is not running]\n', false);
                    return;
                }

                // Read log from file
                return L.resolveDefault(
                    L.Request.get('/cgi-bin/luci/admin/services/dae/log_content'),
                    { response: '' }
                ).then(function(response) {
                    if (response && response.response) {
                        self._appendLog(response.response, true);
                    }
                });
            }).catch(function(e) {
                // Poll error is non-critical
            });
        }, 3);
    },

    _appendLog: function(text, replace) {
        if (!this.logEl) return;

        if (replace) {
            this.logContent = text;
        } else {
            this.logContent += text;
        }

        // Limit lines
        var lines = this.logContent.split('\n');
        if (lines.length > this.MAX_LINES) {
            lines = lines.slice(-this.MAX_LINES);
            this.logContent = lines.join('\n');
        }

        this._renderLog();
    },

    _renderLog: function() {
        if (!this.logEl) return;

        var lines = this.logContent.split('\n');
        var filter = this.currentFilter;
        var fragment = document.createDocumentFragment();
        var matchCount = 0;
        var totalLines = 0;

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i];
            if (!line.trim()) continue;

            totalLines++;

            // Apply filter
            if (filter && line.toLowerCase().indexOf(filter) === -1) {
                continue;
            }
            matchCount++;

            var lineEl = E('div', { 'class': 'dae-log-line' });

            // Detect log level and apply class
            var levelClass = '';
            if (/\b(error|fatal|panic)\b/i.test(line)) {
                levelClass = 'level-error';
            } else if (/\b(warn(?:ing)?)\b/i.test(line)) {
                levelClass = 'level-warn';
            } else if (/\b(info)\b/i.test(line)) {
                levelClass = 'level-info';
            } else if (/\b(debug|trace)\b/i.test(line)) {
                levelClass = 'level-debug';
            }
            if (levelClass) {
                lineEl.classList.add(levelClass);
            }

            // Highlight IP addresses
            var html = this._escapeHtml(line);
            html = html.replace(
                /\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/g,
                '<span class="dae-ip">$1</span>'
            );

            // Highlight filter matches
            if (filter) {
                var escapedFilter = filter.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
                var re = new RegExp('(' + escapedFilter + ')', 'gi');
                html = html.replace(re, '<span class="dae-filter-match">$1</span>');
            }

            lineEl.innerHTML = html;
            fragment.appendChild(lineEl);
        }

        dom.content(this.logEl, fragment);

        // Update line count
        if (this.lineCountEl) {
            if (filter) {
                this.lineCountEl.textContent = matchCount + '/' + totalLines + ' lines';
            } else {
                this.lineCountEl.textContent = totalLines + ' lines';
            }
        }

        // Auto-scroll to bottom if not paused and user is near bottom
        if (!this.paused) {
            var el = this.logEl;
            var nearBottom = (el.scrollHeight - el.scrollTop - el.clientHeight) < 100;
            if (nearBottom) {
                el.scrollTop = el.scrollHeight;
            }
        }
    },

    _applyFilter: function() {
        this._renderLog();
    },

    _togglePause: function() {
        this.paused = !this.paused;
        if (this.paused) {
            this.pauseBtn.classList.add('active');
            this.pauseBtn.textContent = _('Resume');
        } else {
            this.pauseBtn.classList.remove('active');
            this.pauseBtn.textContent = _('Pause');
        }
    },

    _clearLog: function() {
        this.logContent = '';
        if (this.logEl) {
            dom.content(this.logEl,
                E('div', { 'class': 'dae-log-line' }, _('Log cleared')));
        }
        if (this.lineCountEl) {
            this.lineCountEl.textContent = '0 lines';
        }
    },

    _scrollUp: function() {
        if (this.logEl) {
            this.logEl.scrollTop = 0;
        }
    },

    _scrollDown: function() {
        if (this.logEl) {
            this.logEl.scrollTop = this.logEl.scrollHeight;
        }
    },

    _escapeHtml: function(str) {
        return str
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }
});
