const fs = require('fs');
const path = require('path');
const text = fs.readFileSync(path.join(__dirname, 'main.js'), 'utf8');
const regex = /(?:'|\"|\`)\/(?:api|v1|v1beta|rpc)\/[a-zA-Z_/{}:-]+/g;
const matches = [...text.matchAll(regex)];
const unique = new Set(matches.map(m => m[0].slice(1)));
console.log([...unique].join('\n'));
