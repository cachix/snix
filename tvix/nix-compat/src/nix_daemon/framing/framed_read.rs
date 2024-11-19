use std::{
    io::Result,
    pin::Pin,
    task::{ready, Poll},
};

use pin_project_lite::pin_project;
use tokio::io::{AsyncRead, ReadBuf};

/// State machine for [`NixFramedReader`].
///
/// As the reader progresses it linearly cycles through the states.
#[derive(Debug)]
enum NixFramedReaderState {
    /// The reader always starts in this state.
    ///
    /// Before the payload, the client first sends its size.
    /// The size is a u64 which is 8 bytes long, while it's likely that we will receive
    /// the whole u64 in one read, it's possible that it will arrive in smaller chunks.
    /// So in this state we read up to 8 bytes and transition to
    /// [`NixFramedReaderState::ReadingPayload`] when done if the read size is not zero,
    /// otherwise we reset filled to 0, and read the next size value.
    ReadingSize { buf: [u8; 8], filled: usize },
    /// This is where we read the actual payload that is sent to us.
    ///
    /// Once we've read the expected number of bytes, we go back to the
    /// [`NixFramedReaderState::ReadingSize`] state.
    ReadingPayload {
        /// Represents the remaining number of bytes we expect to read based on the value
        /// read in the previous state.
        remaining: u64,
    },
}

pin_project! {
    /// Implements Nix's Framed reader protocol for protocol versions >= 1.23.
    ///
    /// See serialization.md#framed and [`NixFramedReaderState`] for details.
    pub struct NixFramedReader<R> {
        #[pin]
        reader: R,
        state: NixFramedReaderState,
    }
}

impl<R> NixFramedReader<R> {
    pub fn new(reader: R) -> Self {
        Self {
            reader,
            state: NixFramedReaderState::ReadingSize {
                buf: [0; 8],
                filled: 0,
            },
        }
    }
}

impl<R: AsyncRead> AsyncRead for NixFramedReader<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        read_buf: &mut ReadBuf<'_>,
    ) -> Poll<Result<()>> {
        let mut this = self.as_mut().project();
        match this.state {
            NixFramedReaderState::ReadingSize { buf, filled } => {
                if *filled < buf.len() {
                    let mut size_buf = ReadBuf::new(buf);
                    size_buf.advance(*filled);

                    ready!(this.reader.poll_read(cx, &mut size_buf))?;
                    let bytes_read = size_buf.filled().len() - *filled;
                    if bytes_read == 0 {
                        // oef
                        return Poll::Ready(Ok(()));
                    }
                    *filled += bytes_read;
                    // Schedule ourselves to run again.
                    return self.poll_read(cx, read_buf);
                }
                let size = u64::from_le_bytes(*buf);
                if size == 0 {
                    // eof
                    *filled = 0;
                    return Poll::Ready(Ok(()));
                }
                *this.state = NixFramedReaderState::ReadingPayload { remaining: size };
                self.poll_read(cx, read_buf)
            }
            NixFramedReaderState::ReadingPayload { remaining } => {
                // Make sure we never try to read more than usize which is 4 bytes on 32-bit platforms.
                let safe_remaining = if *remaining <= usize::MAX as u64 {
                    *remaining as usize
                } else {
                    usize::MAX
                };
                if safe_remaining > 0 {
                    // The buffer is no larger than the amount of data that we expect.
                    // Otherwise we will trim the buffer below and come back here.
                    if read_buf.remaining() <= safe_remaining {
                        let filled_before = read_buf.filled().len();

                        ready!(this.reader.as_mut().poll_read(cx, read_buf))?;
                        let bytes_read = read_buf.filled().len() - filled_before;

                        *remaining -= bytes_read as u64;
                        if *remaining == 0 {
                            *this.state = NixFramedReaderState::ReadingSize {
                                buf: [0; 8],
                                filled: 0,
                            };
                        }
                        return Poll::Ready(Ok(()));
                    }
                    // Don't read more than remaining + pad bytes, it avoids unnecessary allocations and makes
                    // internal bookkeeping simpler.
                    let mut smaller_buf = read_buf.take(safe_remaining);
                    ready!(self.as_mut().poll_read(cx, &mut smaller_buf))?;

                    let bytes_read = smaller_buf.filled().len();

                    // SAFETY: we just read this number of bytes into read_buf's backing slice above.
                    unsafe { read_buf.assume_init(bytes_read) };
                    read_buf.advance(bytes_read);
                    return Poll::Ready(Ok(()));
                }
                *this.state = NixFramedReaderState::ReadingSize {
                    buf: [0; 8],
                    filled: 0,
                };
                self.poll_read(cx, read_buf)
            }
        }
    }
}

#[cfg(test)]
mod nix_framed_tests {
    use std::time::Duration;

    use tokio::io::AsyncReadExt;
    use tokio_test::io::Builder;

    use crate::nix_daemon::framing::NixFramedReader;

    #[tokio::test]
    async fn read_hello_world_in_two_frames() {
        let mut mock = Builder::new()
            // The client sends len
            .read(&5u64.to_le_bytes())
            // Immediately followed by the bytes
            .read("hello".as_bytes())
            .wait(Duration::ZERO)
            // Send more data separately
            .read(&6u64.to_le_bytes())
            .read(" world".as_bytes())
            .build();

        let mut reader = NixFramedReader::new(&mut mock);
        let mut result = String::new();
        reader
            .read_to_string(&mut result)
            .await
            .expect("Could not read into result");
        assert_eq!("hello world", result);
    }
    #[tokio::test]
    async fn read_hello_world_in_two_frames_followed_by_zero_sized_frame() {
        let mut mock = Builder::new()
            // The client sends len
            .read(&5u64.to_le_bytes())
            // Immediately followed by the bytes
            .read("hello".as_bytes())
            .wait(Duration::ZERO)
            // Send more data separately
            .read(&6u64.to_le_bytes())
            .read(" world".as_bytes())
            .read(&0u64.to_le_bytes())
            .build();

        let mut reader = NixFramedReader::new(&mut mock);
        let mut result = String::new();
        reader
            .read_to_string(&mut result)
            .await
            .expect("Could not read into result");
        assert_eq!("hello world", result);
    }
}
