let sdkPromise

function loadMetaSdk(appId, version) {
  if (window.FB) {
    window.FB.init({appId, autoLogAppEvents: true, xfbml: false, version})
    return Promise.resolve(window.FB)
  }

  if (sdkPromise) return sdkPromise

  sdkPromise = new Promise((resolve, reject) => {
    const previousInit = window.fbAsyncInit

    window.fbAsyncInit = () => {
      if (previousInit) previousInit()
      window.FB.init({appId, autoLogAppEvents: true, xfbml: false, version})
      resolve(window.FB)
    }

    const script = document.createElement("script")
    script.id = "meta-jssdk"
    script.async = true
    script.defer = true
    script.crossOrigin = "anonymous"
    script.src = "https://connect.facebook.net/en_US/sdk.js"
    script.onerror = () => reject(new Error("Meta SDK failed to load"))
    document.head.appendChild(script)
  })

  return sdkPromise
}

function trustedMetaOrigin(origin) {
  try {
    const {protocol, hostname} = new URL(origin)
    return protocol === "https:" && (hostname === "facebook.com" || hostname.endsWith(".facebook.com"))
  } catch (_error) {
    return false
  }
}

function parseMessage(data) {
  if (typeof data === "string") {
    try {
      return JSON.parse(data)
    } catch (_error) {
      return null
    }
  }

  return data && typeof data === "object" ? data : null
}

export const WhatsAppEmbeddedSignup = {
  mounted() {
    this.authorizationCode = null
    this.signupSession = null
    this.submitted = false
    this.active = false

    this.onClick = event => {
      const button = event.target.closest("[data-whatsapp-launch]")
      if (!button || !this.el.contains(button)) return
      this.launch(button)
    }

    this.onMessage = event => {
      if (!this.active || !trustedMetaOrigin(event.origin)) return

      const message = parseMessage(event.data)
      if (message?.type !== "WA_EMBEDDED_SIGNUP") return

      if (message.event === "FINISH") {
        const data = message.data || {}
        if (data.business_id && data.waba_id && data.phone_number_id) {
          this.signupSession = {
            business_id: String(data.business_id),
            waba_id: String(data.waba_id),
            phone_number_id: String(data.phone_number_id),
          }
          this.submitWhenReady()
        } else {
          this.finish("Meta signup finished without a phone number.", true)
        }
      } else if (message.event === "CANCEL" || message.event === "ERROR") {
        const detail = message.data?.error_message || "WhatsApp signup was cancelled."
        this.finish(detail, true)
      }
    }

    this.el.addEventListener("click", this.onClick)
    window.addEventListener("message", this.onMessage)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("message", this.onMessage)
    if (this.pairTimer) window.clearTimeout(this.pairTimer)
  },

  async launch(button) {
    this.authorizationCode = null
    this.signupSession = null
    this.submitted = false
    this.connectionId = button.dataset.whatsappConnectionId || null
    this.active = true
    if (this.pairTimer) window.clearTimeout(this.pairTimer)
    this.pairTimer = null
    this.setBusy(true)
    this.setStatus("Opening Meta signup…")

    try {
      const facebook = await loadMetaSdk(this.el.dataset.appId, this.el.dataset.graphVersion)

      facebook.login(response => {
        const code = response.authResponse?.code

        if (code) {
          this.authorizationCode = code
          this.submitWhenReady()
        } else {
          this.finish("Meta did not return an authorization code.", true)
        }
      }, {
        config_id: this.el.dataset.configId,
        response_type: "code",
        override_default_response_type: true,
        extras: {},
      })
    } catch (_error) {
      this.finish("Could not load Meta signup. Try again.", true)
    }
  },

  submitWhenReady() {
    if (!this.authorizationCode || !this.signupSession) {
      if (!this.pairTimer) {
        this.pairTimer = window.setTimeout(() => {
          this.finish("Meta signup did not return a complete result. Try again.", true)
        }, 15000)
      }
      return
    }

    if (this.submitted) return
    this.submitted = true
    if (this.pairTimer) window.clearTimeout(this.pairTimer)
    this.pairTimer = null
    this.setStatus("Verifying WhatsApp with Meta…")

    this.pushEvent("whatsapp_signup_complete", {
      authorization_code: this.authorizationCode,
      connection_id: this.connectionId,
      session: this.signupSession,
      transaction: this.el.dataset.transaction,
    }, reply => {
      this.finish(
        reply.ok ? "WhatsApp connected." : "WhatsApp could not be connected.",
        !reply.ok,
      )
    })
  },

  finish(message, isError) {
    if (this.pairTimer) window.clearTimeout(this.pairTimer)
    this.pairTimer = null
    this.active = false
    this.setBusy(false)
    this.setStatus(message, isError)
  },

  setBusy(busy) {
    this.el.querySelectorAll("[data-whatsapp-launch]").forEach(button => {
      button.disabled = busy
    })
  },

  setStatus(message, isError = false) {
    const status = this.el.querySelector("[data-whatsapp-signup-status]")
    if (!status) return
    status.textContent = message
    status.classList.toggle("text-error", isError)
    status.classList.toggle("text-ink-muted", !isError)
  },
}
