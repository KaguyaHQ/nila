// Direct-to-storage uploaders for LiveView's `external:` upload configs.
//
// The default LiveView uploader streams a file over the channel in 64 KB
// chunks and waits for the server to acknowledge each one before reading the
// next. One chunk is ever in flight, so a file costs `size / 64KB` serialized
// round trips — minutes of waiting on an origin that is a few hundred
// milliseconds away, for bills that are only a few hundred kilobytes.
//
// A single PUT to the presigned URL is one round trip, and the bytes go to
// Cloudflare's nearest edge instead of the origin.
export const Uploaders = {
  Put(entries, onViewError) {
    entries.forEach((entry) => {
      const xhr = new XMLHttpRequest()

      // A LiveView that dies mid-upload leaves nothing to report progress to.
      onViewError(() => xhr.abort())

      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) {
          entry.progress(100)
        } else {
          entry.error()
        }
      }
      xhr.onerror = () => entry.error()
      xhr.onabort = () => entry.error()

      // Real bytes-on-the-wire progress. `entry.progress(100)` is what marks
      // the entry done, so it is left to `onload` — reporting it from here
      // would call the file finished while the store is still writing it.
      xhr.upload.addEventListener("progress", (event) => {
        if (!event.lengthComputable) return
        const percent = Math.round((event.loaded / event.total) * 100)
        if (percent < 100) entry.progress(percent)
      })

      xhr.open("PUT", entry.meta.url, true)
      xhr.send(entry.file)
    })
  },
}
