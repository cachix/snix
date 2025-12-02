use tonic::transport::Channel;

use crate::buildservice::{BuildEvent, BuildRequest};
use crate::proto::{self, build_service_client::BuildServiceClient};

use super::{BuildEventStream, BuildService};

pub struct GRPCBuildService {
    client: BuildServiceClient<Channel>,
}

impl GRPCBuildService {
    #[allow(dead_code)]
    pub fn from_client(client: BuildServiceClient<Channel>) -> Self {
        Self { client }
    }
}

impl BuildService for GRPCBuildService {
    fn do_build(&self, request: BuildRequest) -> BuildEventStream {
        let mut client = self.client.clone();
        let proto_request: proto::BuildRequest = request.into();

        let stream = async_stream::try_stream! {
            let response = client
                .do_build(proto_request)
                .await
                .map_err(std::io::Error::other)?;

            let mut stream = response.into_inner();

            while let Some(event) = stream.message().await.map_err(std::io::Error::other)? {
                let event: BuildEvent = event.try_into().map_err(std::io::Error::other)?;
                yield event;
            }
        };

        Box::pin(stream)
    }
}
