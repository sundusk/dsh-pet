import { readFileSync, writeFileSync } from 'node:fs'

const body = readFileSync(new URL('../src/client.js', import.meta.url), 'utf8')
const wrapped = `window.__ModuleLoader__.load({
  id: "@sundusk/dsh-pet",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
${body}
    return module.exports;
  },
});
`
writeFileSync(new URL('../lib/client.js', import.meta.url), wrapped)
