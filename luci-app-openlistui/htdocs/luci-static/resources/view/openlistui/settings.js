'use strict';
'require view';
'require form';
'require uci';
'require request';
'require ui';
'require poll';
'require dom';
'require rpc';

(function() {
	return view.extend({
		callGetSettings: function() {
			return request.get('/cgi-bin/luci/admin/services/openlistui/settings_get');
		},

		callSaveSettings: function(data) {
			return request.post('/cgi-bin/luci/admin/services/openlistui/settings_save', data);
		},

		callGeneratePassword: function() {
			return request.get('/cgi-bin/luci/admin/services/openlistui/generate_password');
		},

		callTestGitHubToken: function() {
			return request.get('/cgi-bin/luci/admin/services/openlistui/test_github_token');
		},

		load: function() {
			return Promise.all([
				uci.load('openlistui')
			]);
		},

		render: function(data) {
			var m, s, o, ss, tab;

			m = new form.Map('openlistui', _('OpenList Settings'), 
				_('Configure OpenList services, storage, and application settings'));

			// OpenList Service Tab
			s = m.section(form.NamedSection, 'main', 'openlistui', _('OpenList Service'));
			s.addremove = false;
			s.anonymous = false;

			// Network Configuration
			ss = s.section(form.TypedSection, 'main', _('Network Configuration'));
			ss.addremove = false;
			ss.anonymous = true;

			o = ss.option(form.Value, 'port', _('Listen Port'));
			o.datatype = 'port';
			o.default = '5244';
			o.placeholder = '5244';
			o.description = _('Port number for OpenList web interface (1024-65535)');

			o = ss.option(form.Value, 'data_dir', _('Data Directory'));
			o.default = '/etc/openlistui';
			o.placeholder = '/etc/openlistui';
			o.description = _('Directory where OpenList stores its data and configuration');

			o = ss.option(form.Flag, 'enable_https', _('Enable SSL (HTTPS)'));
			o.default = '0';
			o.description = _('Use HTTPS for secure connections');

			o = ss.option(form.Flag, 'cors_enabled', _('Allow External Access'));
			o.default = '0';
			o.description = _('Allow access from external networks (Controls OpenWrt firewall rules for HTTP, FTP, SFTP and S3 ports based on config.json)');

			// Startup Options
			o = ss.option(form.Flag, 'auto_start', _('Auto Start on Boot'));
			o.default = '1';
			o.description = _('Automatically start OpenList service when system boots');

			// Administrator Password
			o = ss.option(form.Value, 'admin_password', _('Administrator Password'));
			o.password = true;
			o.placeholder = _('Enter custom password');
			o.description = _('Administrator password for OpenList web interface');

			// Add password generation button
			var self = this;
			o.render = function(view, section_id) {
				var input = form.Value.prototype.render.apply(this, [view, section_id]);
				
				input.querySelector('input').style.width = 'calc(100% - 280px)';
				input.querySelector('input').style.display = 'inline-block';
				
				var btnContainer = dom.create('div', { 'style': 'display: inline-block; margin-left: 10px;' }, [
					dom.create('button', {
						'class': 'btn cbi-button cbi-button-action',
						'type': 'button',
						'click': function() {
							ui.showModal(_('Generating Password'), [
								dom.create('p', _('Please wait...'))
							]);
							
							return self.callGeneratePassword().then(function(res) {
								ui.hideModal();
								if (res && res.json && res.json.success) {
									input.querySelector('input').value = res.json.password;
									ui.addNotification(null, _('Random password generated successfully'), 'info');
								} else {
									ui.addNotification(null, _('Failed to generate password'), 'error');
								}
							}).catch(function(err) {
								ui.hideModal();
								ui.addNotification(null, _('Failed to generate password: %s').format(err.message), 'error');
							});
						}
					}, _('Generate Random')),
					' ',
					dom.create('button', {
						'class': 'btn cbi-button cbi-button-action',
						'type': 'button',
						'click': function() {
							var inp = input.querySelector('input');
							if (inp.type === 'password') {
								inp.type = 'text';
								this.textContent = _('Hide');
							} else {
								inp.type = 'password';
								this.textContent = _('Show');
							}
						}
					}, _('Show'))
				]);
				
				input.appendChild(btnContainer);
				return input;
			};

			// Application Settings Tab
			s = m.section(form.NamedSection, 'integration', 'openlistui', _('Application Settings'));
			s.addremove = false;
			s.anonymous = false;

			o = s.option(form.Value, 'github_proxy', _('GitHub Proxy'));
			o.placeholder = 'https://ghfast.top';
			o.description = _('Optional. Enter proxy address to accelerate GitHub access. Example: https://ghfast.top');

			o = s.option(form.Value, 'github_token', _('GitHub Token'));
			o.placeholder = 'ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
			o.description = _('Optional. Enter GitHub Personal Access Token to avoid API rate limits (60/hour → 5000/hour). Generate at: https://github.com/settings/tokens');
			o.password = true;

			// Logging Settings
			o = s.option(form.Flag, 'enable_logging', _('Enable Logging'), _('Enable application logging to file'));
			o.default = '1';

			o = s.option(form.Value, 'log_file', _('Log File Path'), _('Path to the log file'));
			o.default = '/var/log/openlistui.log';
			o.depends('enable_logging', '1');

			o = s.option(form.Value, 'log_max_size', _('Max Log Size (MB)'), _('Maximum size of log file in megabytes'));
			o.default = '4';
			o.datatype = 'uinteger';
			o.depends('enable_logging', '1');

			o = s.option(form.Value, 'log_cache_hours', _('Log Cache Hours'), _('Number of hours to keep logs cached'));
			o.default = '48';
			o.datatype = 'uinteger';
			o.depends('enable_logging', '1');

			// Add test button for GitHub Token
			o = s.option(form.DummyValue, '_github_token_test', _('Test GitHub Token'));
			o.description = _('Click to test GitHub token validity and check current rate limits');
			o.render = function() {
				return dom.create('div', { 'class': 'cbi-value' }, [
					dom.create('label', { 'class': 'cbi-value-title' }, _('Test GitHub Token')),
					dom.create('div', { 'class': 'cbi-value-field' }, [
						dom.create('button', {
							'class': 'btn cbi-button cbi-button-save',
							'type': 'button',
							'click': function(ev) {
								var token = document.querySelector('input[data-name="github_token"]').value;
								if (!token || token.trim() === '') {
									ui.addNotification(null, _('Please enter a GitHub token first'), 'warning');
									return;
								}

								ui.showModal(_('Testing GitHub Token'), [
									dom.create('p', _('Testing token validity and checking rate limits, please wait...'))
								]);

								return self.callTestGitHubToken().then(function(res) {
									ui.hideModal();
									if (res && res.json) {
										if (res.json.success) {
											var message = res.json.message;
											if (res.json.rate_limit && typeof res.json.rate_limit === 'object') {
												message += '\n\nRate Limit Status:\n';
												message += '• Limit: ' + res.json.rate_limit.limit + '/hour\n';
												message += '• Remaining: ' + res.json.rate_limit.remaining + '\n';
												if (res.json.rate_limit.reset_date) {
													message += '• Resets at: ' + res.json.rate_limit.reset_date;
												}
											}
											ui.addNotification(null, message, 'info');
										} else {
											ui.addNotification(null, res.json.message || _('GitHub token test failed'), 'error');
										}
									} else {
										ui.addNotification(null, _('Failed to test GitHub token'), 'error');
									}
								}).catch(function(err) {
									ui.hideModal();
									ui.addNotification(null, _('Error testing GitHub token: ') + err, 'error');
								});
							}
						}, _('Test Token'))
					])
				]);
			};

			return m.render();
		},

		handleSave: function() {
			return this.save();
		},

		handleSaveApply: function() {
			return this.save().then(function() {
				location.reload();
			});
		},

		handleReset: function() {
			return this.load();
		}
	});
})();
