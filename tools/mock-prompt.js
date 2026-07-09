#!/usr/bin/env node
/**
 * A stand-in for a coding agent's permission menu, used by the integration test.
 *
 * Rendering and key handling mirror the real harnesses:
 *   gemini — BaseSelectionList.js: '●' marks the highlighted row, two spaces
 *            otherwise, then "N." and the label. Arrow keys wrap around.
 *   claude — the menu is framed in a rounded box, '❯' marks the highlighted
 *            row, and long labels wrap onto an indented continuation line.
 *
 * On Enter it writes the chosen label to --out and exits, so the test can
 * assert which option the watcher actually confirmed.
 */
'use strict';

const fs = require('fs');

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const style = arg('--style', 'gemini');
const out = arg('--out', '');
let index = parseInt(arg('--start', '1'), 10) - 1;

const MENUS = {
  gemini: {
    question: "Allow execution of: 'rm'?",
    items: [
      'Allow once',
      'Allow for this session',
      'Allow for all future sessions',
      'Modify with external editor',
      'No, suggest changes (esc)',
    ],
  },
  claude: {
    question: 'Do you want to proceed?',
    items: [
      'Yes',
      "Yes, and don't ask again for npm commands in /Users/oldcai",
      'No, and tell Claude what to do differently (esc)',
    ],
  },
};

const menu = MENUS[style];
if (!menu) {
  console.error(`unknown style: ${style}`);
  process.exit(2);
}

function renderGemini() {
  const lines = ['', `  Shell  rm -rf ./build`, '', menu.question, ''];
  menu.items.forEach((label, i) => {
    lines.push(`${i === index ? '●' : ' '} ${i + 1}. ${label}`);
  });
  return lines.join('\r\n');
}

function renderClaude() {
  const W = 62;
  const pad = (s) => `│ ${s.padEnd(W)} │`;
  const lines = [`╭${'─'.repeat(W + 2)}╮`, pad('Bash command'), pad(''), pad('  npm install'), pad('')];
  lines.push(pad(menu.question));
  menu.items.forEach((label, i) => {
    const marker = i === index ? '❯' : ' ';
    // Wrap the long label the way Ink does, onto an indented continuation line.
    if (label.length > 44) {
      const cut = label.lastIndexOf(' ', 44);
      lines.push(pad(`${marker} ${i + 1}. ${label.slice(0, cut)}`));
      lines.push(pad(`     ${label.slice(cut + 1)}`));
    } else {
      lines.push(pad(`${marker} ${i + 1}. ${label}`));
    }
  });
  lines.push(`╰${'─'.repeat(W + 2)}╯`);
  return lines.join('\r\n');
}

function draw() {
  const body = style === 'gemini' ? renderGemini() : renderClaude();
  process.stdout.write('\x1b[2J\x1b[H' + body + '\r\n');
}

function choose() {
  const label = menu.items[index];
  if (out) fs.writeFileSync(out, label);
  process.stdout.write(`\r\nCHOSE: ${label}\r\n`);
  process.exit(0);
}

if (process.stdin.isTTY) process.stdin.setRawMode(true);
process.stdin.resume();
process.stdin.on('data', (buf) => {
  const s = buf.toString('binary');
  // tmux sends \x1b[A / \x1b[B for arrows in normal cursor-key mode, and
  // \x1bOA / \x1bOB when the app requested application cursor keys.
  if (s === '\x1b[A' || s === '\x1bOA') {
    index = (index - 1 + menu.items.length) % menu.items.length;
    draw();
  } else if (s === '\x1b[B' || s === '\x1bOB') {
    index = (index + 1) % menu.items.length;
    draw();
  } else if (s === '\r' || s === '\n') {
    choose();
  } else if (s === '\x03') {
    process.exit(130);
  }
});

draw();
