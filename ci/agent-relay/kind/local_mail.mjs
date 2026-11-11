// Disposable local SMTP sink. Mail stays in bounded memory and is never logged.
// Its HTTP reader binds loopback: only kubectl exec can read the sign-in links.
import net from 'node:net';
import http from 'node:http';

const messages = [];
net.createServer(socket => {
  let buffer = '', body = '', data = false;
  socket.setTimeout(30_000, () => socket.destroy());
  socket.write('220 local-mail ESMTP\r\n');
  socket.on('data', chunk => {
    buffer += chunk.toString();
    if (buffer.length + body.length > 524_288) { socket.end('552 message too large\r\n'); return; }
    let end;
    while ((end = buffer.indexOf('\r\n')) >= 0) {
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 2);
      if (data) {
        if (line === '.') {
          messages.push(body); if (messages.length > 20) messages.shift();
          body = ''; data = false; socket.write('250 queued\r\n');
        } else { body += line.replace(/^\.\./, '.') + '\r\n'; }
      } else if (/^(EHLO|HELO)\b/i.test(line)) socket.write('250 local-mail\r\n');
      else if (/^DATA$/i.test(line)) { data = true; socket.write('354 end with dot\r\n'); }
      else if (/^QUIT$/i.test(line)) socket.end('221 bye\r\n');
      else if (/^(MAIL FROM:|RCPT TO:|RSET|NOOP)/i.test(line)) socket.write('250 ok\r\n');
      else socket.write('502 unsupported\r\n');
    }
  });
  socket.on('error', () => {});
}).listen(1025, '0.0.0.0');

http.createServer((request, response) => {
  if (request.method !== 'GET' || request.url !== '/messages') { response.writeHead(404).end(); return; }
  response.setHeader('Content-Type', 'application/json');
  response.end(JSON.stringify(messages));
}).listen(8025, '127.0.0.1');
