import Foundation

struct VideoPlayerHTML {
    static func page(recordingId: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>LocalLoom Recording</title>
          <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
              background: #0a0a0a;
              display: flex;
              justify-content: center;
              align-items: center;
              min-height: 100vh;
              font-family: -apple-system, system-ui, sans-serif;
            }
            .container {
              max-width: 960px;
              width: 100%;
              padding: 20px;
            }
            video {
              width: 100%;
              border-radius: 12px;
              box-shadow: 0 20px 60px rgba(0,0,0,0.5);
            }
            .controls {
              display: flex;
              justify-content: space-between;
              align-items: center;
              margin-top: 16px;
              color: #888;
              font-size: 14px;
            }
            .brand {
              color: #555;
              font-size: 13px;
              margin-top: 24px;
              text-align: center;
            }
            .error-page {
              color: #888;
              text-align: center;
              padding: 60px 20px;
            }
            .error-page h1 {
              color: #ccc;
              font-size: 24px;
              margin-bottom: 12px;
            }
          </style>
        </head>
        <body>
          <div class="container">
            <video src="/media/\(recordingId).mp4" controls autoplay playsinline></video>
            <div class="controls">
              <span>Shared via LocalLoom</span>
              <span class="duration"></span>
            </div>
            <div class="brand">localloom</div>
          </div>
          <script>
            const video = document.querySelector('video');
            const durationEl = document.querySelector('.duration');
            video.addEventListener('loadedmetadata', () => {
              const mins = Math.floor(video.duration / 60);
              const secs = Math.floor(video.duration % 60);
              durationEl.textContent = mins + ':' + String(secs).padStart(2, '0');
            });
          </script>
        </body>
        </html>
        """
    }

    static func notFoundPage() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>LocalLoom - Not Found</title>
          <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
              background: #0a0a0a;
              display: flex;
              justify-content: center;
              align-items: center;
              min-height: 100vh;
              font-family: -apple-system, system-ui, sans-serif;
              color: #888;
            }
            .container { text-align: center; padding: 60px 20px; }
            h1 { color: #ccc; font-size: 24px; margin-bottom: 12px; }
            p { font-size: 16px; }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>Recording Not Found</h1>
            <p>This recording may have been deleted or is no longer available.</p>
          </div>
        </body>
        </html>
        """
    }

    static func noRecordingsPage() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>LocalLoom</title>
          <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
              background: #0a0a0a;
              display: flex;
              justify-content: center;
              align-items: center;
              min-height: 100vh;
              font-family: -apple-system, system-ui, sans-serif;
              color: #888;
            }
            .container { text-align: center; padding: 60px 20px; }
            h1 { color: #ccc; font-size: 24px; margin-bottom: 12px; }
            p { font-size: 16px; }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>LocalLoom</h1>
            <p>No recordings yet. Press Cmd+Shift+L to start recording!</p>
          </div>
        </body>
        </html>
        """
    }
}
