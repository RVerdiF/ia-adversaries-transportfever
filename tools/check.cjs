const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const parser = require('./lua/node_modules/luaparse');
const root = path.resolve(__dirname, '..');
const files = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    const name = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(name);
    else if (entry.name.endsWith('.lua')) files.push(name);
  }
}
walk(path.join(root, 'content'));
walk(path.join(root, 'tests'));
for (const file of files) {
  try { parser.parse(fs.readFileSync(file, 'utf8'), {luaVersion: '5.3'}); }
  catch (error) { error.message = path.relative(root, file) + ': ' + error.message; throw error; }
}
const manifest = JSON.parse(fs.readFileSync(path.join(root, '_content.json'), 'utf8'));
const listed = new Set(manifest.files);
for (const file of files.filter(file => file.startsWith(path.join(root, 'content') + path.sep))) {
  const relative = path.relative(path.join(root, 'content'), file).replaceAll(path.sep, '/');
  if (!listed.has(relative)) throw new Error(`Missing resource in manifest: ${relative}`);
}
for (const relative of listed) {
  if (path.isAbsolute(relative) || relative.includes('..')) throw new Error('Invalid manifest resource path');
  if (!fs.existsSync(path.join(root, 'content', relative))) throw new Error(`Missing file: ${relative}`);
}
JSON.parse(fs.readFileSync(path.join(root, 'mod.json'), 'utf8'));
JSON.parse(fs.readFileSync(path.join(root, '_metadata/modinfo.json'), 'utf8'));
console.log(`Syntax and manifest passed (${files.length} Lua files)`);
const cli = path.join(__dirname, 'lua/node_modules/fengari-node-cli/src/lua-cli.js');
for (const test of fs.readdirSync(path.join(root, 'tests')).filter(name => name.endsWith('_test.lua')).sort()) {
  const run = cp.spawnSync(process.execPath, [cli, 'tests/' + test], {cwd: root, encoding: 'utf8'});
  process.stdout.write(run.stdout || '');
  process.stderr.write(run.stderr || '');
  // The upstream CLI can report Lua errors with exit code 0. Assertions and
  // stack traces on stderr must also fail the verification runner.
  if (run.status !== 0 || run.stderr || run.error) process.exit(1);
}
