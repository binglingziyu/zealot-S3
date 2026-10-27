import { Controller } from "@hotwired/stimulus"
import { createSHA256, sha256 } from "hash-wasm"

export default class extends Controller {
  static targets = ["file", "progress", "status", "submit", "cancel", "retry"]
  static values = { kind: String }

  disconnect() {
    this.stopped = true
    this.abort?.abort()
  }

  async api(path, method = "GET", data) {
    const response = await fetch(`/upload_sessions${path}`, {
      method, credentials: "same-origin", signal: this.abort.signal,
      headers: { Accept: "application/json", "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content },
      body: data ? JSON.stringify(data) : undefined
    })
    const value = await response.json().catch(() => { throw new Error("登录已过期或服务暂时不可用，请刷新页面后重试。") })
    if (!response.ok) throw new Error(value.error || `HTTP ${response.status}`)
    return value
  }

  async start(event) {
    event.preventDefault()
    if (this.busy) return
    const file = this.fileTarget.files[0]
    if (!file) return
    this.busy = true
    this.stopped = false
    this.abort = new AbortController()
    this.submitTarget.disabled = true
    this.retryTarget.hidden = true
    this.cancelTarget.hidden = false
    try {
      this.statusTarget.textContent = "正在校验文件…"
      const hasher = await createSHA256()
      hasher.init()
      for (let offset = 0; offset < file.size; offset += 4 * 1024 * 1024) {
        if (this.stopped) return
        hasher.update(new Uint8Array(await file.slice(offset, offset + 4 * 1024 * 1024).arrayBuffer()))
      }
      const digest = hasher.digest()
      const metadata = Object.fromEntries(new FormData(this.element))
      const fingerprint = await sha256([metadata.channel_key, this.kindValue, file.name, digest].join(":"))
      this.storageKey = `zealot-upload:${fingerprint}`
      const nonce = localStorage.getItem(this.storageKey) || Array.from(crypto.getRandomValues(new Uint32Array(4))).join("-")
      localStorage.setItem(this.storageKey, nonce)
      let session = await this.api("", "POST", { ...metadata, filename: file.name, byte_size: file.size,
        sha256: digest, kind: this.kindValue, idempotency_key: `${fingerprint}:${nonce}` })
      this.session = session
      if (["cancelled", "expired"].includes(session.state)) {
        localStorage.removeItem(this.storageKey)
        throw new Error("上次上传已取消或过期，请点击上传创建新会话。")
      }
      if (["initiated", "uploading"].includes(session.state)) {
        const remote = await this.api(`/${session.id}/parts`)
        const uploaded = new Map(remote.parts.map(part => [part.part_number, part.byte_size]))
        const count = Math.ceil(file.size / session.part_size)
        const pending = []
        let completed = 0
        if (["initiated", "uploading"].includes(remote.state)) {
          for (let number = 1; number <= count; number++) {
            const size = Math.min(session.part_size, file.size - (number - 1) * session.part_size)
            if (uploaded.get(number) === size) completed += size
            else pending.push({ number, size })
          }
          const worker = async () => {
            while (pending.length && !this.stopped) {
              const { number, size } = pending.shift()
              for (let attempt = 0; attempt < 3; attempt++) {
                try {
                  const signed = await this.api(`/${session.id}/parts`, "POST", { part_numbers: [number] })
                  const response = await fetch(signed.parts[0].url, { method: "PUT", credentials: "omit",
                    signal: this.abort.signal, body: file.slice((number - 1) * session.part_size, (number - 1) * session.part_size + size) })
                  if (!response.ok) throw new Error(`对象存储返回 HTTP ${response.status}`)
                  break
                } catch (error) {
                  if (attempt === 2 || this.stopped) throw error
                  await new Promise(resolve => setTimeout(resolve, (attempt + 1) * 1000))
                }
              }
              completed += size
              this.progressTarget.value = completed / file.size * 100
              this.statusTarget.textContent = `上传中 ${Math.round(completed / file.size * 100)}%`
            }
          }
          await Promise.all([worker(), worker(), worker()])
        }
        if (this.stopped) return
        session = await this.api(`/${session.id}/complete`, "POST")
      }
      await this.waitForResult(session)
    } catch (error) {
      if (!this.stopped) {
        this.abort.abort()
        this.statusTarget.textContent = `${error.message} 可点击“上传 / 继续”重试。`
      }
    } finally {
      this.busy = false
      this.submitTarget.disabled = false
    }
  }

  async waitForResult(session) {
    this.cancelTarget.hidden = true
    while (!this.stopped) {
      this.session = session
      if (session.state === "ready") {
        this.progressTarget.value = 100
        this.statusTarget.textContent = "解析完成。"
        window.location.assign(session.result_path)
        return
      }
      if (session.state === "failed") {
        this.retryTarget.hidden = false
        throw new Error(`解析失败：${session.error}`)
      }
      if (["cancelled", "expired"].includes(session.state)) throw new Error(`上传状态：${session.state}`)
      this.statusTarget.textContent = "上传完成，服务器正在校验和解析…"
      await new Promise(resolve => setTimeout(resolve, 2000))
      if (!this.stopped) session = await this.api(`/${session.id}`)
    }
  }

  async retry() {
    if (this.busy || !this.session) return
    this.busy = true
    this.abort = new AbortController()
    this.retryTarget.hidden = true
    try { await this.waitForResult(await this.api(`/${this.session.id}/retry_parse`, "POST")) }
    catch (error) { this.statusTarget.textContent = error.message; this.retryTarget.hidden = false }
    finally { this.busy = false }
  }

  async cancel() {
    this.stopped = true
    this.abort?.abort()
    this.abort = new AbortController()
    try {
      if (this.session) await this.api(`/${this.session.id}`, "DELETE")
      if (this.storageKey) localStorage.removeItem(this.storageKey)
      this.statusTarget.textContent = "上传已取消。"
      this.cancelTarget.hidden = true
    } catch (error) { this.statusTarget.textContent = `取消失败：${error.message}` }
  }
}
