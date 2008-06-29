unit OtlComm;

interface

uses
  Variants,
  SpinLock,
  GpLists,
  GpStuff,
  DSiWin32,
  OtlCommon;

const
  CDefaultQueueSize = 65520 div 20 {3276 entries; 20 = SizeOf(TOmniMessage)};

type
  TOmniMessage = record
    MsgID  : word;
    MsgData: TOmniValue;
  end; { TOmniMessage }

  IOmniCommunicationEndpoint = interface ['{910D329C-D049-48B9-B0C0-9434D2E57870}']
    function  GetNewMessageEvent: THandle;
  //
    procedure RemoveMonitor;
    procedure Send(msgID: word; msgData: TOmniValue); overload;
    procedure Send(msgID: word; msgData: array of const); overload;
    procedure Send(const msg: TOmniMessage); overload;
    procedure SetMonitor(hWindow: THandle; messageWParam, messageLParam: integer);
    function  Receive(var msgID: word; var msgData: TOmniValue): boolean; overload;
    function  Receive(var msg: TOmniMessage): boolean; overload;
    property NewMessageEvent: THandle read GetNewMessageEvent;
  end; { IOmniTaskCommunication }

  IOmniTwoWayChannel = interface ['{3ED1AB88-4209-4E01-AA79-A577AD719520}']
    function Endpoint1: IOmniCommunicationEndpoint;
    function Endpoint2: IOmniCommunicationEndpoint;
  end; { IOmniTwoWayChannel }

  function CreateTwoWayChannel(queueSize: integer = CDefaultQueueSize): IOmniTwoWayChannel;

implementation

uses
  Windows,
  SysUtils,
  OtlTaskEvents;

type
  {:Fixed-size ring buffer of TOmniValues references.
  }
  TOmniRingBuffer = class
  strict private
    orbBuffer              : array of TOmniMessage;
    orbBufferSize          : integer;
    orbCount               : TGp4AlignedInt;
    orbHead                : integer;
    orbLock                : TSpinLock;
    orbMonitorMessageLParam: integer;
    orbMonitorMessageWParam: integer;
    orbMonitorWindow       : TGp4AlignedInt;
    orbNewMessageEvt       : TDSiEventHandle;
    orbTail                : integer;
  strict protected
    function  IncPointer(const ptr: integer; increment: integer = 1): integer; inline;
  public
    constructor Create(bufferSize: integer);
    destructor  Destroy; override;
    procedure Clear; inline;
    function  Count: integer; inline;
    function  Dequeue: TOmniMessage;
    function  Enqueue(value: TOmniMessage): boolean;
    function  IsEmpty: boolean; inline;
    function  IsFull: boolean; inline;
    procedure Lock; inline;
    procedure RemoveMonitor;
    procedure SetMonitor(hWindow: THandle; messageWParam, messageLParam: integer);
    procedure Unlock; inline;
    property NewMessageEvent: TDSiEventHandle read orbNewMessageEvt write orbNewMessageEvt;
  end; { TOmniRingBuffer }

  TOmniCommunicationEndpoint = class(TInterfacedObject, IOmniCommunicationEndpoint)
  strict private
    ceReader_ref: TOmniRingBuffer;
    ceWriter_ref: TOmniRingBuffer;
  protected
    function  GetNewMessageEvent: THandle;
  public
    constructor Create(readQueue, writeQueue: TOmniRingBuffer);
    function  Receive(var msg: TOmniMessage): boolean; overload; inline;
    function  Receive(var msgID: word; var msgData: TOmniValue): boolean; overload; inline;
    procedure RemoveMonitor; inline;
    procedure Send(const msg: TOmniMessage); overload; inline;
    procedure Send(msgID: word; msgData: array of const); overload; 
    procedure Send(msgID: word; msgData: TOmniValue); overload; inline;
    procedure SetMonitor(hWindow: THandle; messageWParam, messageLParam: integer); inline;
    property NewMessageEvent: THandle read GetNewMessageEvent;
  end; { TOmniCommunicationEndpoint }

  TOmniTwoWayChannel = class(TInterfacedObject, IOmniTwoWayChannel)
  strict private
    twcEndpoint        : array [1..2] of IOmniCommunicationEndpoint;
    twcLock            : TSpinLock;
    twcMessageQueueSize: integer;
    twcUnidirQueue     : array [1..2] of TOmniRingBuffer;
  strict protected
    procedure CreateBuffers; {inline;} // TODO 1 -oPrimoz Gabrijelcic : testing, remove! 
  public
    constructor Create(messageQueueSize: integer);
    destructor  Destroy; override;
    function Endpoint1: IOmniCommunicationEndpoint; inline;
    function Endpoint2: IOmniCommunicationEndpoint; inline;
  end; { TOmniTwoWayChannel }

{ exports }

function CreateTwoWayChannel(queueSize: integer = CDefaultQueueSize): IOmniTwoWayChannel;
begin
  Result := TOmniTwoWayChannel.Create(queueSize);
end; { CreateTwoWayChannel }

{ TOmniRingBuffer }

constructor TOmniRingBuffer.Create(bufferSize: integer);
begin
  orbLock := TSpinLock.Create;
  orbBufferSize := bufferSize;
  SetLength(orbBuffer, orbBufferSize+1);
  orbNewMessageEvt := CreateEvent(nil, false, false, nil);
  Win32Check(orbNewMessageEvt <> 0);
  Assert(SizeOf(THandle) = SizeOf(cardinal));
  orbMonitorWindow.Value := 0;
end; { TOmniRingBuffer.Create }

{:Destroys ring buffer. If OwnsObjects is set, destroys all objects currently
  in the buffer.
}
destructor TOmniRingBuffer.Destroy;
begin
  DSiCloseHandleAndNull(orbNewMessageEvt);
  Clear;
  FreeAndNil(orbLock);
  inherited;
end; { TOmniRingBuffer.Destroy }

procedure TOmniRingBuffer.Clear;
begin
  Lock;
  try
    orbTail := orbHead;
    orbCount.Value := 0;
  finally Unlock; end;
end; { TOmniRingBuffer.Clear }

{:Returns number of objects in the buffer.
}
function TOmniRingBuffer.Count: integer;
begin
  Result := orbCount;
end; { TOmniRingBuffer.Count }

{:Removes tail object from the buffer, without destroying it. Returns nil if
  buffer is empty.
}
function TOmniRingBuffer.Dequeue: TOmniMessage;
begin
  Lock;
  try
    if IsEmpty then
      raise Exception.Create('TOmniRingBuffer.Dequeue: Ring buffer is empty')
    else begin
      Result := orbBuffer[orbTail];
      orbTail := IncPointer(orbTail);
      orbCount.Value := orbCount - 1;
      if orbCount > 0 then
        SetEvent(orbNewMessageEvt);
    end;
  finally Unlock; end;
end; { TOmniRingBuffer.Dequeue }

{:Inserts object into the buffer. Returns false if the buffer is full.
}
function TOmniRingBuffer.Enqueue(value: TOmniMessage): boolean;
begin
  Lock;
  try
    if IsFull then
      Result := false
    else begin
      orbBuffer[orbHead] := value;
      orbHead := IncPointer(orbHead);
      orbCount.Value := orbCount + 1;
      SetEvent(orbNewMessageEvt);
      if orbMonitorWindow <> 0 then
        PostMessage(orbMonitorWindow, COmniTaskMsg_NewMessage, orbMonitorMessageWParam,
          orbMonitorMessageLParam);
      Result := true;
    end;
  finally Unlock; end;
end; { TOmniRingBuffer.Enqueue }

{:Increments internal pointer (head or tail), wraps it to the buffer size and
  returns new value.
}
function TOmniRingBuffer.IncPointer(const ptr: integer;
  increment: integer): integer;
begin
  Result := (ptr + increment) mod (orbBufferSize + 1);
end; { TOmniRingBuffer.IncPointer }

{:Checks whether the buffer is empty.
}
function TOmniRingBuffer.IsEmpty: boolean;
begin
  Result := (orbCount = 0);
end; { TOmniRingBuffer.IsEmpty }

function TOmniRingBuffer.IsFull: boolean;
begin
  Result := (orbCount = orbBufferSize);
end; { TOmniRingBuffer.IsFull }

procedure TOmniRingBuffer.Lock;
begin
  orbLock.Acquire;
end; { TOmniRingBuffer.Lock }

procedure TOmniRingBuffer.RemoveMonitor;
begin
  orbMonitorWindow.Value := 0;
end; { TOmniRingBuffer.RemoveMonitor }

procedure TOmniRingBuffer.SetMonitor(hWindow: THandle; messageWParam, messageLParam:
  integer);
begin
  Lock;
  try
    orbMonitorWindow.Value := cardinal(hWindow);
    orbMonitorMessageWParam := messageWParam;
    orbMonitorMessageLParam := messageLParam;
  finally Unlock; end;
end; { TOmniRingBuffer.SetMonitor }

procedure TOmniRingBuffer.Unlock;
begin
  orbLock.Release;
end; { TOmniRingBuffer.Unlock }

{ TOmniCommunicationEndpoint }

constructor TOmniCommunicationEndpoint.Create(readQueue, writeQueue: TOmniRingBuffer);
begin
  inherited Create;
  ceReader_ref := readQueue;
  ceWriter_ref := writeQueue;
end; { TOmniCommunicationEndpoint.Create }

function TOmniCommunicationEndpoint.GetNewMessageEvent: THandle;
begin
  Result := ceReader_ref.NewMessageEvent;
end; { TOmniCommunicationEndpoint.GetNewMessageEvent }

function TOmniCommunicationEndpoint.Receive(var msgID: word; var msgData:
  TOmniValue): boolean;
var
  msg: TOmniMessage;
begin
  Result := Receive(msg);
  if Result then begin
    msgID := msg.msgID;
    msgData := msg.msgData;
  end;
end; { TOmniCommunicationEndpoint.Receive }

function TOmniCommunicationEndpoint.Receive(var msg: TOmniMessage): boolean;
begin
  Result := not ceReader_ref.IsEmpty;
  if Result then
    msg := ceReader_ref.Dequeue;
end; { TOmniCommunicationEndpoint.Receive }

procedure TOmniCommunicationEndpoint.RemoveMonitor;
begin
  ceWriter_ref.RemoveMonitor;
end; { TOmniCommunicationEndpoint.RemoveMonitor }

procedure TOmniCommunicationEndpoint.Send(const msg: TOmniMessage);
begin
  if not ceWriter_ref.Enqueue(msg) then
    raise Exception.Create('TOmniCommunicationEndpoint.Send: Queue is full');
end; { TOmniCommunicationEndpoint.Send }

procedure TOmniCommunicationEndpoint.Send(msgID: word; msgData: TOmniValue);
var
  msg: TOmniMessage;
begin
  msg.msgID := msgID;
  msg.msgData := msgData;
  Send(msg);
end; { TOmniCommunicationEndpoint.Send }

procedure TOmniCommunicationEndpoint.Send(msgID: word; msgData: array of const);
begin
  Send(msgID, OpenArrayToVarArray(msgData));
end; { TOmniCommunicationEndpoint.Send }

procedure TOmniCommunicationEndpoint.SetMonitor(hWindow: THandle; messageWParam,
  messageLParam: integer);
begin
  ceWriter_ref.SetMonitor(hWindow, messageWParam, messageLParam);
end; { TOmniCommunicationEndpoint.SetMonitor }

{ TOmniTwoWayChannel }

constructor TOmniTwoWayChannel.Create(messageQueueSize: integer);
begin
  inherited Create;
  twcMessageQueueSize := messageQueueSize;
  twcLock := TSpinLock.Create;
end; { TOmniTwoWayChannel.Create }

destructor TOmniTwoWayChannel.Destroy;
begin
  twcUnidirQueue[1].Free;
  twcUnidirQueue[1] := nil;
  twcUnidirQueue[2].Free;
  twcUnidirQueue[2] := nil;
  FreeAndNil(twcLock);
  inherited;
end; { TOmniTwoWayChannel.Destroy }

procedure TOmniTwoWayChannel.CreateBuffers;
begin
  if twcUnidirQueue[1] = nil then
    twcUnidirQueue[1] := TOmniRingBuffer.Create(twcMessageQueueSize);
  if twcUnidirQueue[2] = nil then
    twcUnidirQueue[2] := TOmniRingBuffer.Create(twcMessageQueueSize);
end; { TOmniTwoWayChannel.CreateBuffers }

function TOmniTwoWayChannel.Endpoint1: IOmniCommunicationEndpoint;
begin
  Assert((cardinal(@twcEndpoint[1]) AND 3) = 0);
  if twcEndpoint[1] = nil then begin
    twcLock.Acquire;
    try
      if twcEndpoint[1] = nil then begin
        CreateBuffers;
        twcEndpoint[1] := TOmniCommunicationEndpoint.Create(twcUnidirQueue[1], twcUnidirQueue[2]);
      end;
    finally twcLock.Release; end;
  end;
  Result := twcEndpoint[1];
end; { TOmniTwoWayChannel.Endpoint1 }

function TOmniTwoWayChannel.Endpoint2: IOmniCommunicationEndpoint;
begin
  Assert((cardinal(@twcEndpoint[2]) AND 3) = 0);
  if twcEndpoint[2] = nil then begin
    twcLock.Acquire;
    try
      if twcEndpoint[2] = nil then begin
        CreateBuffers;
        twcEndpoint[2] := TOmniCommunicationEndpoint.Create(twcUnidirQueue[2], twcUnidirQueue[1]);
      end;
    finally twcLock.Release; end;
  end;
  Result := twcEndpoint[2];
end; { TOmniTwoWayChannel.Endpoint2 }

end.