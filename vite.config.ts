import fs from 'node:fs'
import { request as httpRequest } from 'node:http'
import { connect as netConnect } from 'node:net'
import os from 'node:os'
import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import { tanstackRouter } from '@tanstack/router-plugin/vite'
import react from '@vitejs/plugin-react'
import { defineConfig, type Plugin, type UserConfig } from 'vite'

const MIME: Record<string, string> = {
  '.json': 'application/json; charset=utf-8',
  '.csv': 'text/csv; charset=utf-8',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.xml': 'application/xml; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
}

// 开发与预览时：
// 1. 直接挂载仓库根目录下的 data/、thumbs/、img/，避免拷贝 6.8 GB 素材
// 2. 提供 /api/proxy 同源转发接口，解决 DashScope (Qwen) / 火山方舟 (Doubao) 官方接口的浏览器 CORS 限制
function localAssetsAndProxyPlugin(): Plugin {
  const rootDir = import.meta.dirname
  const prefixes = ['/data/', '/thumbs/', '/img/', '/og-cover.jpg', '/robots.txt', '/sitemap.xml']

  const handleProxy = async (req: any, res: any) => {
    try {
      const targetUrl = req.headers['x-target-url'] as string | undefined
      if (!targetUrl || !/^https?:\/\//i.test(targetUrl)) {
        res.statusCode = 400
        res.setHeader('Content-Type', 'application/json; charset=utf-8')
        res.end(JSON.stringify({ error: { message: 'Missing or invalid x-target-url header' } }))
        return
      }

      const chunks: Buffer[] = []
      for await (const chunk of req) {
        chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
      }
      const rawBody = Buffer.concat(chunks)

      const forwardHeaders: Record<string, string> = {}
      const contentType = req.headers['content-type']
      if (contentType) forwardHeaders['Content-Type'] = contentType
      const auth = req.headers['authorization']
      if (auth) forwardHeaders['Authorization'] = auth
      const googKey = req.headers['x-goog-api-key']
      if (googKey) forwardHeaders['x-goog-api-key'] = googKey as string
      const dashAsync = req.headers['x-dashscope-async']
      if (dashAsync) forwardHeaders['X-DashScope-Async'] = dashAsync as string

      const upstream = await fetch(targetUrl, {
        method: req.method || 'POST',
        headers: forwardHeaders,
        body: rawBody.length > 0 ? rawBody : undefined,
      })

      res.statusCode = upstream.status
      const upType = upstream.headers.get('content-type') || 'application/json; charset=utf-8'
      res.setHeader('Content-Type', upType)
      const ab = await upstream.arrayBuffer()
      res.end(Buffer.from(ab))
    } catch (err: any) {
      res.statusCode = 502
      res.setHeader('Content-Type', 'application/json; charset=utf-8')
      res.end(JSON.stringify({ error: { message: err?.message || 'Proxy request failed' } }))
    }
  }

  const serve = (req: any, res: any, next: any) => {
    const rawUrl = (req.url || '').split('?')[0]
    if (rawUrl === '/api/proxy') {
      void handleProxy(req, res)
      return
    }
    const decoded = decodeURIComponent(rawUrl)
    if (!prefixes.some((p) => decoded === p || decoded.startsWith(p))) {
      return next()
    }
    const filePath = path.join(rootDir, decoded)
    if (!filePath.startsWith(rootDir) || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
      return next()
    }
    const ext = path.extname(filePath).toLowerCase()
    res.setHeader('Content-Type', MIME[ext] || 'application/octet-stream')
    res.setHeader('Cache-Control', 'public, max-age=3600')
    fs.createReadStream(filePath).pipe(res)
  }

  return {
    name: 'local-assets-and-proxy-plugin',
    configureServer(server) {
      server.middlewares.use(serve)
    },
    configurePreviewServer(server) {
      server.middlewares.use(serve)
    },
  }
}

// 本地 ComfyUI 同源代理：浏览器请求 /comfy/* → ComfyUI。
// 转发时会去掉浏览器 Origin，所以不需要给 ComfyUI 加 --enable-cors-header。
// 目标端口 **每次请求实时探测**（Desktop 版默认 8000、便携版/源码版默认 8188）：
// 这样 ComfyUI 比网页晚启动、或换端口重启，都不用重启网页；也避免了"启动时探测失败就永久指向空端口"。
const COMFY_CANDIDATE_PORTS = ['http://127.0.0.1:8000', 'http://127.0.0.1:8188']

async function probeComfyUi(): Promise<string> {
  const explicit = process.env.COMFYUI_URL?.trim()
  if (explicit) return explicit.replace(/\/+$/, '')
  for (const base of COMFY_CANDIDATE_PORTS) {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 500)
    try {
      const res = await fetch(`${base}/system_stats`, { signal: controller.signal })
      if (res.ok) {
        const data = (await res.json()) as { system?: unknown }
        if (data.system) return base
      }
    }
    catch {
      // 该端口没有 ComfyUI，继续探测下一个
    }
    finally {
      clearTimeout(timer)
    }
  }
  return ''
}

function createComfyProxyPlugin(): Plugin {
  let cache: { url: string, at: number } | null = null

  /** /comfy 请求日志：排查局域网设备"生成了但页面收不到结果"时用 */
  const logFile = path.join(os.tmpdir(), 'comfy-proxy.log')
  function logComfyRequest(
    ip: string,
    method: string | undefined,
    url: string,
    status: number,
    ms: number,
    bytes: number,
    note?: string,
  ) {
    try {
      const line = `${new Date().toISOString()} ${ip} ${method} ${url.slice(0, 160)} -> ${status} ${ms}ms ${bytes}B${note ? ` (${note})` : ''}\n`
      fs.appendFileSync(logFile, line)
    }
    catch {
      // 记日志失败不影响代理
    }
  }

  async function resolveTarget(): Promise<string> {
    if (cache && Date.now() - cache.at < 3000) return cache.url
    const url = await probeComfyUi()
    if (url) cache = { url, at: Date.now() }
    return url
  }

  function handleHttp(req: any, res: any, next: any) {
    const rawUrl: string = req.url || ''
    const rawPath = rawUrl.split('?')[0]
    if (rawPath !== '/comfy' && !rawPath.startsWith('/comfy/')) return next()

    void (async () => {
      const startedAt = Date.now()
      const clientIp = String(req.socket?.remoteAddress || '').replace(/^::ffff:/, '')
      const base = await resolveTarget()
      if (!base) {
        res.statusCode = 502
        res.setHeader('Content-Type', 'application/json; charset=utf-8')
        res.end(JSON.stringify({ error: { message: '未检测到运行中的 ComfyUI（8000/8188 均无响应），请先启动 ComfyUI' } }))
        logComfyRequest(clientIp, req.method, rawUrl, 502, Date.now() - startedAt, 0)
        return
      }
      const upstream = new URL(base)
      const headers: Record<string, any> = { ...req.headers }
      // ComfyUI 对带 Origin 的跨源请求做校验，转发时去掉，按同源请求处理
      delete headers.host
      delete headers.origin
      delete headers.referer

      const proxyReq = httpRequest(
        {
          hostname: upstream.hostname,
          port: upstream.port,
          path: rawUrl.replace(/^\/comfy/, '') || '/',
          method: req.method,
          headers,
        },
        (proxyRes) => {
          res.writeHead(proxyRes.statusCode || 502, proxyRes.headers)
          let bytes = 0
          proxyRes.on('data', (chunk: Buffer) => { bytes += chunk.length })
          proxyRes.on('end', () => logComfyRequest(clientIp, req.method, rawUrl, proxyRes.statusCode || 0, Date.now() - startedAt, bytes))
          proxyRes.pipe(res)
        },
      )
      proxyReq.on('error', (err: Error) => {
        if (!res.headersSent) {
          res.statusCode = 502
          res.setHeader('Content-Type', 'application/json; charset=utf-8')
        }
        res.end(JSON.stringify({ error: { message: `ComfyUI 代理失败：${err.message}` } }))
        logComfyRequest(clientIp, req.method, rawUrl, 502, Date.now() - startedAt, 0, err.message)
      })
      req.pipe(proxyReq)
    })()
  }

  /** 进度推送用的 WebSocket：/comfy/ws → ComfyUI /ws，按原始 TCP 隧道转发 */
  function attachUpgrade(httpServer: any) {
    if (!httpServer) return
    httpServer.on('upgrade', (req: any, socket: any, head: Buffer) => {
      const rawPath: string = (req.url || '').split('?')[0]
      if (rawPath !== '/comfy' && !rawPath.startsWith('/comfy/')) return

      void (async () => {
        const clientIp = String(socket.remoteAddress || '').replace(/^::ffff:/, '')
        const base = await resolveTarget()
        if (!base) {
          logComfyRequest(clientIp, 'WS', rawPath, 502, 0, 0, 'no comfyui')
          socket.destroy()
          return
        }
        const upstream = new URL(base)
        const connectedAt = Date.now()
        const targetSocket = netConnect(Number(upstream.port || 80), upstream.hostname, () => {
          logComfyRequest(clientIp, 'WS', rawPath, 101, Date.now() - connectedAt, 0, 'upgrade ok')
          const lines = [
            `${req.method} ${(req.url || '').replace(/^\/comfy/, '') || '/'} HTTP/1.1`,
            `Host: ${upstream.host}`,
          ]
          for (const [key, value] of Object.entries(req.headers)) {
            const name = key.toLowerCase()
            if (name === 'host' || name === 'origin' || name === 'referer') continue
            lines.push(`${key}: ${Array.isArray(value) ? value.join(', ') : value}`)
          }
          targetSocket.write(`${lines.join('\r\n')}\r\n\r\n`)
          if (head && head.length) targetSocket.write(head)
          targetSocket.pipe(socket)
          socket.pipe(targetSocket)
        })
        socket.on('close', () => logComfyRequest(clientIp, 'WS', rawPath, 0, Date.now() - connectedAt, 0, 'closed'))
        targetSocket.on('error', () => socket.destroy())
        socket.on('error', () => targetSocket.destroy())
      })()
    })
  }

  return {
    name: 'comfyui-same-origin-proxy',
    configureServer(server) {
      server.middlewares.use(handleHttp)
      attachUpgrade(server.httpServer)
    },
    configurePreviewServer(server) {
      server.middlewares.use(handleHttp)
      attachUpgrade(server.httpServer)
    },
  }
}

export default defineConfig(async (): Promise<UserConfig> => {
  const comfyuiUrl = await probeComfyUi()
  console.log(comfyuiUrl
    ? `[comfy] 启动时检测到 ComfyUI：${comfyuiUrl}（/comfy 每次请求都会重新探测，换端口无需重启）`
    : '[comfy] 启动时未检测到 ComfyUI，/comfy 会在收到请求时继续探测 8000/8188')

  return {
    publicDir: false,
    plugins: [
      localAssetsAndProxyPlugin(),
      createComfyProxyPlugin(),
      tanstackRouter({ target: 'react', autoCodeSplitting: true }),
      react(),
      tailwindcss(),
    ],
    resolve: {
      alias: { '@': path.resolve(import.meta.dirname, './src') },
    },
    build: {
      rolldownOptions: {
        output: {
          codeSplitting: {
            groups: [
              { name: 'react-vendor', test: /node_modules[\\/](react|react-dom|scheduler)[\\/]/ },
              { name: 'tanstack-vendor', test: /node_modules[\\/]@tanstack[\\/]/ },
              { name: 'ui-vendor', test: /node_modules[\\/](radix-ui|@radix-ui|lucide-react|sonner)[\\/]/ },
            ],
          },
        },
      },
    },
    server: {
      port: 5173,
      // 局域网访问：Vite 6+ 默认只放行 localhost 与 IP 形式的 Host 头，
      // 用设备名（如 my-pc.local:5173）访问会返回 403 Blocked request，这里放开。
      // 仅影响 dev / preview server，不影响生产构建产物。
      allowedHosts: true,
    },
    preview: {
      allowedHosts: true,
    },
  }
})
