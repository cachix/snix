use std::{
    num::NonZeroU64,
    pin::Pin,
    task::{self, ready, Poll},
};

use pin_project_lite::pin_project;
use tokio::io::{self, AsyncRead, ReadBuf};

/// State machine for [`NixFramedReader`].
///
/// We read length-prefixed chunks until we receive a zero-sized payload indicating EOF.
/// Other than the zero-sized terminating chunk, chunk boundaries are not considered meaningful.
/// Lengths are 64-bit little endian values on the wire.
#[derive(Debug, Eq, PartialEq)]
enum State {
    Length { buf: [u8; 8], filled: u8 },
    Chunk { remaining: NonZeroU64 },
    Eof,
}

pin_project! {
    /// Implements Nix's [Framed] reader protocol for protocol versions >= 1.23.
    ///
    /// Unexpected EOF on the underlying reader is returned as [UnexpectedEof][`std::io::ErrorKind::UnexpectedEof`].
    /// True EOF (end-of-stream) is fused.
    ///
    /// [Framed]: https://snix.dev/docs/reference/nix-daemon-protocol/types/#framed
    pub struct NixFramedReader<R> {
        #[pin]
        reader: R,
        state: State,
    }
}

impl<R> NixFramedReader<R> {
    pub fn new(reader: R) -> Self {
        Self {
            reader,
            state: State::Length {
                buf: [0; 8],
                filled: 0,
            },
        }
    }

    /// Returns `true` if the Nix Framed reader has reached EOF.
    #[must_use]
    pub fn is_eof(&self) -> bool {
        matches!(self.state, State::Eof)
    }
}

impl<R: AsyncRead> AsyncRead for NixFramedReader<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut task::Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let mut this = self.as_mut().project();

        // reading nothing always succeeds
        if buf.remaining() == 0 {
            return Ok(()).into();
        }

        loop {
            let reader = this.reader.as_mut();
            match this.state {
                State::Eof => {
                    return Ok(()).into();
                }
                State::Length { buf, filled } => {
                    let bytes_read = {
                        let mut b = ReadBuf::new(&mut buf[*filled as usize..]);
                        ready!(reader.poll_read(cx, &mut b))?;
                        b.filled().len() as u8
                    };

                    if bytes_read == 0 {
                        return Err(io::ErrorKind::UnexpectedEof.into()).into();
                    }

                    *filled += bytes_read;

                    if *filled == 8 {
                        *this.state = match NonZeroU64::new(u64::from_le_bytes(*buf)) {
                            None => State::Eof,
                            Some(remaining) => State::Chunk { remaining },
                        };
                    }
                }
                State::Chunk { remaining } => {
                    let bytes_read = ready!(with_limited(buf, remaining.get(), |buf| {
                        reader.poll_read(cx, buf).map_ok(|()| buf.filled().len())
                    }))?;

                    *this.state = match NonZeroU64::new(remaining.get() - bytes_read as u64) {
                        None => State::Length {
                            buf: [0; 8],
                            filled: 0,
                        },
                        Some(remaining) => State::Chunk { remaining },
                    };

                    return if bytes_read == 0 {
                        Err(io::ErrorKind::UnexpectedEof.into())
                    } else {
                        Ok(())
                    }
                    .into();
                }
            }
        }
    }
}

/// Make a limited version of `buf`, consisting only of up to `n` bytes of the unfilled section, and call `f` with it.
/// After `f` returns, we propagate the filled cursor advancement back to `buf`.
// TODO(edef): duplicate of src/wire/bytes/reader/mod.rs:with_limited
fn with_limited<R>(buf: &mut ReadBuf, n: u64, f: impl FnOnce(&mut ReadBuf) -> R) -> R {
    let mut nbuf = buf.take(n.try_into().unwrap_or(usize::MAX));
    let ptr = nbuf.initialized().as_ptr();
    let ret = f(&mut nbuf);

    // SAFETY: `ReadBuf::take` only returns the *unfilled* section of `buf`,
    // so anything filled is new, initialized data.
    //
    // We verify that `nbuf` still points to the same buffer,
    // so we're sure it hasn't been swapped out.
    unsafe {
        // ensure our buffer hasn't been swapped out
        assert_eq!(nbuf.initialized().as_ptr(), ptr);

        let n = nbuf.filled().len();
        buf.assume_init(n);
        buf.advance(n);
    }

    ret
}

#[cfg(test)]
mod nix_framed_tests {
    use std::{
        cmp::min,
        pin::Pin,
        task::{self, Poll},
        time::Duration,
    };

    use tokio::io::{self, AsyncRead, AsyncReadExt, ReadBuf};
    use tokio_test::io::Builder;

    use crate::nix_daemon::framing::NixFramedReader;

    #[tokio::test]
    async fn read_unexpected_eof_after_frame() {
        let mut mock = Builder::new()
            // The client sends len
            .read(&5u64.to_le_bytes())
            // Immediately followed by the bytes
            .read("hello".as_bytes())
            .wait(Duration::ZERO)
            // Send more data separately
            .read(&6u64.to_le_bytes())
            .read(" world".as_bytes())
            // NOTE: no terminating zero
            .build();

        let mut reader = NixFramedReader::new(&mut mock);
        let err = reader.read_to_string(&mut String::new()).await.unwrap_err();
        assert!(!reader.is_eof());
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[tokio::test]
    async fn read_unexpected_eof_in_frame() {
        let mut mock = Builder::new()
            // The client sends len
            .read(&5u64.to_le_bytes())
            // Immediately followed by the bytes
            .read("hello".as_bytes())
            .wait(Duration::ZERO)
            // Send more data separately
            .read(&6u64.to_le_bytes())
            .read(" worl".as_bytes())
            // NOTE: we only sent five bytes of data before EOF
            .build();

        let mut reader = NixFramedReader::new(&mut mock);
        let err = reader.read_to_string(&mut String::new()).await.unwrap_err();
        assert!(!reader.is_eof());
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[tokio::test]
    async fn read_unexpected_eof_in_length() {
        let mut mock = Builder::new()
            // The client sends len
            .read(&5u64.to_le_bytes())
            // Immediately followed by the bytes
            .read("hello".as_bytes())
            .wait(Duration::ZERO)
            // Send a truncated length header
            .read(&[0; 7])
            .build();

        let mut reader = NixFramedReader::new(&mut mock);
        let err = reader.read_to_string(&mut String::new()).await.unwrap_err();
        assert!(!reader.is_eof());
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
    }

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
            .read(&0u64.to_le_bytes())
            .build();

        let mut reader = NixFramedReader::new(&mut mock);
        let mut result = String::new();
        reader
            .read_to_string(&mut result)
            .await
            .expect("Could not read into result");
        assert_eq!("hello world", result);
        assert!(reader.is_eof());
    }

    struct SplitMock<'a>(&'a [u8]);

    impl AsyncRead for SplitMock<'_> {
        fn poll_read(
            mut self: Pin<&mut Self>,
            _cx: &mut task::Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            let data = self.0;

            if data.is_empty() {
                Poll::Pending
            } else {
                let n = min(buf.remaining(), data.len());
                buf.put_slice(&data[..n]);
                self.0 = &data[n..];

                Poll::Ready(Ok(()))
            }
        }
    }

    /// Somewhat of a fuzz test, ensuring that we end up in identical states for the same input,
    /// independent of how it is spread across read calls and poll cycles.
    #[test]
    fn split_verif() {
        let mut cx = task::Context::from_waker(task::Waker::noop());
        let mut input = make_framed(&[b"hello", b"world", b"!", b""]);
        let framed_end = input.len();
        input.extend_from_slice(b"trailing data");

        for end_point in 0..input.len() {
            let input = &input[..end_point];

            let unsplit_res = {
                let mut dut = NixFramedReader::new(SplitMock(input));
                let mut data_buf = vec![0; input.len()];
                let mut read_buf = ReadBuf::new(&mut data_buf);

                for _ in 0..256 {
                    match Pin::new(&mut dut).poll_read(&mut cx, &mut read_buf) {
                        Poll::Ready(res) => res.unwrap(),
                        Poll::Pending => break,
                    }
                }

                let len = read_buf.filled().len();
                data_buf.truncate(len);

                assert_eq!(
                    end_point >= framed_end,
                    dut.is_eof(),
                    "end_point = {end_point}, state = {:?}",
                    dut.state
                );
                (dut.state, data_buf, dut.reader.0)
            };

            for split_point in 1..end_point.saturating_sub(1) {
                let split_res = {
                    let mut dut = NixFramedReader::new(SplitMock(&[]));
                    let mut data_buf = vec![0; input.len()];
                    let mut read_buf = ReadBuf::new(&mut data_buf);

                    dut.reader.0 = &input[..split_point];
                    for _ in 0..256 {
                        match Pin::new(&mut dut).poll_read(&mut cx, &mut read_buf) {
                            Poll::Ready(res) => res.unwrap(),
                            Poll::Pending => break,
                        }
                    }

                    dut.reader.0 = &input[split_point - dut.reader.0.len()..];
                    for _ in 0..256 {
                        match Pin::new(&mut dut).poll_read(&mut cx, &mut read_buf) {
                            Poll::Ready(res) => res.unwrap(),
                            Poll::Pending => break,
                        }
                    }

                    let len = read_buf.filled().len();
                    data_buf.truncate(len);

                    (dut.state, data_buf, dut.reader.0)
                };

                assert_eq!(split_res, unsplit_res);
            }
        }
    }

    /// Make framed data, given frame contents. Terminating frame is *not* implicitly included.
    /// Include an empty slice explicitly.
    fn make_framed(frames: &[&[u8]]) -> Vec<u8> {
        let mut buf = vec![];

        for &data in frames {
            buf.extend_from_slice(&(data.len() as u64).to_le_bytes());
            buf.extend_from_slice(data);
        }

        buf
    }
}
