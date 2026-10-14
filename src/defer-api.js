/**
 * @fileoverview Minimal HTTP listener for triggering server actions via internal webhooks.
 * Acts as a proxy to execute the bds-manager CLI subcommands.
 */
const http = require('http');
const { exec } = require('child_process');

const PORT = 3456;
const SERVER_DIR = '/home/moo/MooVoidSMP/SMP';
const SCRIPT_PATH = `${SERVER_DIR}/bds-manager.sh`;
const SKIP_FILE = `${SERVER_DIR}/.skip`;

/**
 * Handles incoming HTTP requests and executes the corresponding manager scripts.
 * @param {http.IncomingMessage} req 
 * @param {http.ServerResponse} res 
 */
const requestHandler = (req, res) => {
    if (req.method === 'POST' && req.url === '/defer') {
        exec(`${SCRIPT_PATH} defer`, (error) => {
            if (error) {
                console.error(`[API] Defer execution failed: ${error.message}`);
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ status: 'error', detail: error.message }));
                return;
            }
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ status: 'success' }));
        });
        return;
    }

    if (req.method === 'POST' && req.url === '/restart') {
        let body = '';
        req.on('data', chunk => {
            body += chunk.toString();
        });
        
        req.on('end', () => {
            let payload = {};
            try { 
                if (body) {
                    payload = JSON.parse(body);
                }
            } catch (err) {}
            
            const mins = parseInt(payload.minutes, 10);
            const cmdArgs = (!isNaN(mins) && mins > 0 && mins < 60) ? `restart ${mins}` : `restart`;
            const cmd = `rm -f ${SKIP_FILE} && ${SCRIPT_PATH} ${cmdArgs}`;

            exec(cmd, (error) => {
                if (error) {
                    console.error(`[API] Restart execution failed: ${error.message}`);
                    res.writeHead(500, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ status: 'error', detail: error.message }));
                    return;
                }
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ status: 'success' }));
            });
        });
        return;
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
};

const server = http.createServer(requestHandler);

server.listen(PORT, '127.0.0.1', () => {
    console.log(`[API] Listening for internal webhooks on 127.0.0.1:${PORT}`);
});
