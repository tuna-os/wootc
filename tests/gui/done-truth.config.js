import base from './playwright.config.js';
export default {
  ...base,
  use: { ...base.use, baseURL: 'http://127.0.0.1:5664' },
  webServer: {
    command: './node_modules/.bin/http-server ../../app/frontend/dist -p 5664 -s -c-1',
    url: 'http://127.0.0.1:5664',
    reuseExistingServer: false,
    timeout: 30000,
  },
};
