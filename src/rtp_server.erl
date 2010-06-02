-module(rtp_server).
-author('Max Lapshin <max@maxidoors.ru>').

-include_lib("erlmedia/include/h264.hrl").
-include_lib("erlmedia/include/video_frame.hrl").
-include("../include/rtsp.hrl").

-record(rtp_state, {
  rtcp_socket,
  rtp_socket,
  type,
  state
}).

-record(base_rtp, {
  media,
  clock_map,
  base_timecode = undefined,
  sequence = undefined,
  wall_clock = undefined,
  base_wall_clock = undefined,
  timecode = undefined,
  synced = false
}).

-record(video, {
  media,
  clock_map,
  base_timecode = undefined,
  sequence = undefined,
  wall_clock = undefined,
  base_wall_clock = undefined,
  timecode = undefined,
  synced = false,
  h264 = #h264{},
  broken = false,
  buffer = []
}).

-record(audio, {
  media,
  clock_map,
  base_timecode = undefined,
  sequence = undefined,
  wall_clock = undefined,
  base_wall_clock = undefined,
  timecode = undefined,
  synced = false,
  audio_rate,
  audio_headers = <<>>,
  audio_data = <<>>
}).
	


-define(RTCP_SR, 200).
-define(RTCP_SD, 202).
-define(YEARS_70, 2208988800).  % RTP bases its timestamp on NTP. NTP counts from 1900. Shift it to 1970. This constant is not precise.

%% External API
-export([start_link/2]).

%% gen_server callbacks

-export([video/2, audio/2, decode/3, init/2, get_socket/3, wait_data/1]).
-export([configure/2, configure/3, presync/2]).

%%--------------------------------------------------------------------
%% @spec (Media::any(), Stream::rtsp_stream()) -> {ok, Pid} | {error, Reason}
%%
%% @doc Called by a supervisor to start the listening process.
%% @end
%%----------------------------------------------------------------------

start_link(Media, #rtsp_stream{type = Type} = Stream)  ->
  {RTP, RTPSocket, RTCP, RTCPSocket} = open_ports(Type),
  Pid = spawn_link(?MODULE, get_socket, [Type, init(Stream, Media), Media]),
  link(Pid),
  gen_udp:controlling_process(RTPSocket, Pid),
  gen_udp:controlling_process(RTCPSocket, Pid),
  Pid ! {socket, RTPSocket, RTCPSocket},
  {ok, Pid, {RTP, RTCP}}.


configure(Body, RTPStreams) ->
  configure(Body, RTPStreams, self()).

configure(Body, RTPStreams, Media) ->
  Streams = sdp:decode(Body),
  
  {Streams1, Frames} = config_media(Streams),
  
  RtpStreams2 = configure(Streams1, RTPStreams, Media, 0),
  {Streams1, RtpStreams2, Frames}.


configure([], RTPStreams, _, _) -> 
  RTPStreams;

configure([undefined | Streams], RTPStreams, Media, RTP) ->
  configure(Streams, RTPStreams, Media, RTP+2);

configure([#rtsp_stream{} = Stream | Streams], RTPStreams, Media, RTP) ->
  RtpConfig = rtp_server:init(Stream, Media),
  RtpStreams1 = setelement(RTP+1, RTPStreams, {Stream#rtsp_stream.type, RtpConfig}),
  RTPStreams2 = setelement(RTP+2, RtpStreams1, {rtcp, RTP}),
  configure(Streams, RTPStreams2, Media, RTP+2).


presync(Streams, Info) ->
  {Now, _} = erlang:statistics(wall_clock),
  presync(Streams, Info, 1, Now).

presync(Streams, [], _N, _Now) ->
  Streams;

presync(Streams, [_RTP | Info], N, Now) when element(N, Streams) == undefined ->
  presync(Streams, Info, N+2, Now);
  
presync(Streams, [RTP | Info], N, Now) ->
  {Type, Stream} = element(N, Streams),

  RTPSeq = proplists:get_value("seq", RTP),
  RTPTime = proplists:get_value("rtptime", RTP),
  % ?D({"Presync", RTPSeq, RTPTime}),
  Stream1 = setelement(#base_rtp.sequence, Stream, list_to_integer(RTPSeq) - 2),
  Stream2 = setelement(#base_rtp.base_timecode, Stream1, list_to_integer(RTPTime)),
  Stream3 = setelement(#base_rtp.timecode, Stream2, list_to_integer(RTPTime)),
  Stream4 = setelement(#base_rtp.synced, Stream3, true),
  Stream5 = setelement(#base_rtp.wall_clock, Stream4, Now),
  presync(setelement(N, Streams, {Type, Stream5}), Info, N+2, Now).

config_media(Streams) -> config_media(Streams, [], []).

config_media([], Output, Frames) -> {lists:reverse(Output), Frames};
config_media([#rtsp_stream{codec = Codec} | Streams], Output, Frames) when not is_atom(Codec) ->
  ?D({"Unknown rtp codec", Codec}),
  config_media(Streams, [undefined | Output], Frames);

config_media([#rtsp_stream{type = video, pps = PPS, sps = SPS} = Stream | Streams], Output, Frames) ->
  {H264, _} = h264:decode_nal(SPS, #h264{}),
  {H264_2, _} = h264:decode_nal(PPS, H264),
  Configs = case h264:video_config(H264_2) of
    undefined -> [];
    Config -> [Config]
  end,
  config_media(Streams, [Stream#rtsp_stream{config = H264_2} | Output], Configs ++ Frames);

config_media([#rtsp_stream{type = audio, config = Config} = Stream | Streams], Output, Frames) when is_binary(Config) ->
  AudioConfig = #video_frame{       
   	content          = audio,
   	flavor = config,
		dts           = 0,
		pts           = 0,
		body          = Config,
	  codec	    = aac,
	  sound	  = {stereo, bit16, rate44}
	},

  config_media(Streams, [Stream | Output], [AudioConfig | Frames]).


init(#rtsp_stream{type = video, clock_map = ClockMap, config = H264}, Media) ->
  #video{media = Media, clock_map = ClockMap, h264 = H264};

init(#rtsp_stream{type = audio, clock_map = ClockMap}, Media) ->
  #audio{media = Media, clock_map = ClockMap};
  
init(undefined, Media) ->
  undefined.

open_ports(audio) ->
  try_rtp(8000);

open_ports(video) ->
  try_rtp(5000).

try_rtp(40000) ->
  error;
  
try_rtp(Port) ->
  case gen_udp:open(Port, [binary, {active, false}, {recbuf, 1048576}]) of
    {ok, RTPSocket} ->
      try_rtcp(Port, RTPSocket);
    {error, _} ->
      try_rtp(Port + 2)
  end.

try_rtcp(RTP, RTPSocket) ->
  RTCP = RTP+1,
  case gen_udp:open(RTCP, [binary, {active, false}]) of
    {ok, RTCPSocket} ->
      {RTP, RTPSocket, RTCP, RTCPSocket};
    {error, _} ->
      gen_udp:close(RTPSocket),
      try_rtp(RTP + 2)
  end.
  
% 
%  0                   1                   2                   3
%  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
%  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%  |V=2|P|X|  CC   |M|     PT      |       sequence number         |
%  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%  |                           timestamp                           |
%  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%  |           synchronization source (SSRC) identifier            |
%  +=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
%  |            contributing source (CSRC) identifiers             |
%  |                             ....                              |
%  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

get_socket(Type, State, Media) ->
  link(Media),
  receive
    {socket, RTPSocket, RTCPSocket} ->
      inet:setopts(RTPSocket, [{active, true}]),
      inet:setopts(RTCPSocket, [{active, true}]),
      ?MODULE:wait_data(#rtp_state{rtp_socket = RTPSocket, rtcp_socket = RTCPSocket, type = Type, state = State})
  after
    50000 ->
      error_logger:error_msg("RTP socket timeout: ~p~n", [Type])
  end.
  
wait_data(#rtp_state{rtp_socket = RTPSocket, rtcp_socket = RTCPSocket, state = State, type = Type} = RtpStream) ->
  receive
    {udp,RTPSocket,_Host,_Port, Bin} ->
      % read_video(Video, {data, Body, Sequence, Timestamp});
      State1 = decode(Type, State, Bin),
      ?MODULE:wait_data(RtpStream#rtp_state{state = State1});

    {udp,RTCPSocket,_Host,_Port, Bin} ->
      % inet:setopts(RTPSocket, [{active, once}]),
      State1 = decode(rtcp, State, Bin),
      ?MODULE:wait_data(RtpStream#rtp_state{state = State1});
    Else ->
      ?D({"Unknown", Else}),
      ok
  after
    50000 ->
      error_logger:error_msg("RTP timeout: ~p~n", [Type])
  end.

decode(rtcp, State, <<2:2, 0:1, _Count:5, ?RTCP_SR, _Length:16, _StreamId:32, NTP:64, Timecode:32, _PacketCount:32, _OctetCount:32, _/binary>>) ->
  WallClock = round((NTP / 16#100000000 - ?YEARS_70) * 1000),
  % ?D({"RTCP", element(1, State), WallClock, Timecode}),
  _ClockMap = element(#base_rtp.clock_map, State),
  State1 = case element(#base_rtp.base_wall_clock, State) of
    undefined -> setelement(#base_rtp.base_wall_clock, State, WallClock - 2000);
    _ -> State
  end,
  State2 = setelement(#base_rtp.wall_clock, State1, WallClock - element(#base_rtp.base_wall_clock, State1)),
  State3 = setelement(#base_rtp.base_timecode, State2, Timecode),
  State4 = case element(#base_rtp.base_timecode, State) of
    undefined -> State3;
    _ -> State
  end,
  {setelement(#base_rtp.timecode, State4, Timecode), []};
  % State3.

decode(_Type, State, <<2:2, 0:1, _Extension:1, 0:4, _Marker:1, _PayloadType:7, _Sequence:16, _Timecode:32, _StreamId:32, _Data/binary>>) when element(#base_rtp.base_timecode, State) == undefined ->
  {State, []};
  
% decode(Type, State, <<2:2, 0:1, _Extension:1, 0:4, _Marker:1, _PayloadType:7, Sequence:16, Timecode:32, _StreamId:32, Data/binary>>) when element(#base_rtp.base_timecode, State) == undefined ->
%   ?D({autosync),
%   {{Type,State1}} = rtp_server:presync({{Type,State}}, [[{"seq",integer_to_list(Sequence)},{"rtptime",integer_to_list(Timecode)}]]),
%   ?MODULE:Type(State1, {data, Data, Sequence, Timecode});
%   % {State, []};

decode(Type, State, <<2:2, 0:1, _Extension:1, 0:4, _Marker:1, _PayloadType:7, Sequence:16, Timecode:32, _StreamId:32, Data/binary>>)  ->
  % ?D({Type, Sequence, Timecode, element(#base_rtp.base_timecode, State)}),
  ?MODULE:Type(State, {data, Data, Sequence, Timecode}).


convert_timecode(State) ->
  Timecode = element(#base_rtp.timecode, State),
  ClockMap = element(#base_rtp.clock_map, State),
  BaseTimecode = element(#base_rtp.base_timecode, State),
  WallClock = element(#base_rtp.wall_clock, State),
  _BaseWallClock = element(#base_rtp.base_wall_clock, State),
  % ?D({"TC", WallClock, Timecode, BaseTimecode, ClockMap}),
  WallClock + (Timecode - BaseTimecode)/ClockMap.
  

% rtcp(State, {data, _, _, Timestamp} = Packet) ->
%   audio(Audio#audio{base_timecode = Timestamp}, Packet)ю
  
  
audio(#audio{media = _Media, audio_headers = <<>>} = Audio, {data, <<AULength:16, AUHeaders:AULength/bitstring, AudioData/binary>>, _Sequence, _Timestamp}) ->
  unpack_audio_units(Audio#audio{audio_headers = AUHeaders, audio_data = AudioData}, []);
  
audio(#audio{media = _Media, audio_data = AudioData} = Audio, {data, Bin, _Sequence, _Timestamp}) ->
  unpack_audio_units(Audio#audio{audio_data = <<AudioData/binary, Bin/binary>>}, []).


  
unpack_audio_units(#audio{audio_headers = <<>>} = Audio, Frames) ->
  {Audio#audio{audio_headers = <<>>, audio_data = <<>>}, lists:reverse(Frames)};
  
unpack_audio_units(#audio{audio_data = <<>>} = Audio, Frames) ->
  {Audio#audio{audio_headers = <<>>, audio_data = <<>>}, lists:reverse(Frames)};
  
unpack_audio_units(#audio{clock_map = _ClockMap, audio_headers = <<AUSize:13, _Delta:3, AUHeaders/bitstring>>, audio_data = AudioData, timecode = Timecode} = Audio, Frames) ->
  DTS = convert_timecode(Audio),
  % ?D({"Audio", Timecode, Timestamp}),
  case AudioData of
    <<Data:AUSize/binary, Rest/binary>> ->
      AudioFrame = #video_frame{       
        content = audio,
        dts     = DTS,
        pts     = DTS,
        body    = Data,
    	  codec	  = aac,
    	  flavor  = frame,
    	  sound	  = {stereo, bit16, rate44}
      },
      unpack_audio_units(Audio#audio{audio_headers = AUHeaders, audio_data = Rest, timecode = Timecode + 1024}, [AudioFrame | Frames]);
    _ ->
      {Audio, lists:reverse(Frames)}
  end.
    
video(#video{timecode = undefined} = Video, {data, _, _, Timecode} = Packet) ->
  ?D({"No timecode"}),
  video(Video#video{timecode = Timecode}, Packet);

video(#video{sequence = undefined} = Video, {data, _, Sequence, _} = Packet) ->
  ?D({"Reset seq to", Sequence}),
  video(Video#video{sequence = Sequence - 1}, Packet);

video(#video{sequence = PrevSeq} = Video, {data, _, Sequence, _} = Packet) when Sequence /= PrevSeq + 1->
  ?D({PrevSeq + 1, Sequence}),
  video(Video#video{broken = true, sequence = Sequence - 1}, Packet);

video(#video{h264 = H264, buffer = Buffer, timecode = Timecode} = Video, {data, Body, Sequence, Timecode}) ->
  {H264_1, Frames} = h264:decode_nal(Body, H264),
  {Video#video{sequence = Sequence, h264 = H264_1, buffer = Buffer ++ Frames}, []};

video(#video{h264 = _H264, timecode = _Timecode, broken = _Broken} = Video, {data, <<>>, Sequence, NewTimecode}) ->
  ?D({"Warning! Zero frame"}),
  {Video#video{sequence = Sequence, timecode = NewTimecode}};
  
video(#video{h264 = H264, timecode = Timecode, broken = Broken} = Video, {data, Body, Sequence, NewTimecode}) ->

  {Video1, Frames} = case Broken of
    true -> ?D({"Drop broken video frame", Timecode}), {Video, []};
    false -> send_video(Video)
  end,
  {H264_1, NewFrames} = h264:decode_nal(Body, H264),
  % ?D({"ZZZ", Timecode, size(Body), NewFrames}),

  {Video1#video{sequence = Sequence, broken = false, h264 = H264_1, buffer = NewFrames, timecode = NewTimecode}, Frames}.
 
send_video(#video{synced = false, buffer = [#video_frame{flavor = frame} | _]} = Video) ->
  {Video#video{buffer = []}, []};

send_video(#video{buffer = []} = Video) ->
  {Video, []};

send_video(#video{media = _Media, buffer = Frames, timecode = _Timecode, h264 = H264} = Video) ->
  Frame = lists:foldl(fun(_, undefined) -> undefined;
                         (#video_frame{body = NAL} = F, #video_frame{body = NALs}) -> 
                                F#video_frame{body = <<NALs/binary, NAL/binary>>}
  end, #video_frame{body = <<>>}, Frames),
  Timestamp = convert_timecode(Video),
  % ?D({"Video", _Timecode, Timestamp}),
  Frame1 = case Frame of
    undefined -> [];
    _ -> [Frame#video_frame{dts = Timestamp, pts = Timestamp, content = video}]
  end,
  Frame2 = case Frame of 
    #video_frame{flavor = keyframe} -> [h264:video_config(H264) | Frame1];
    _ -> Frame1
  end,
  {Video#video{synced = true, buffer = []}, Frame2}.