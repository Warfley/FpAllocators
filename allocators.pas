unit allocators;

{$mode ObjFPC}{$H+}
{$ModeSwitch advancedrecords}
{$TypedAddress On}

interface

uses
  SysUtils;

type
  EUncopyable = class(Exception);

  TGetMemMethod = function(ASize: SizeInt): Pointer of Object;
  TFreeMemMethod = procedure(p: Pointer) of object;

  { TBaseAllocator }

  TBaseAllocator = record
  private type
    PBaseAllocator = ^TBaseAllocator;

    PAllocMem = ^TAllocMem;

    { TAllocMem }

    TAllocMem = record
      Allocator: PBaseAllocator;
      LastAlloc: PAllocMem;
      NextAlloc: PAllocMem;
      FreeFunc: TFreeMemMethod;
      InstanceSize: SizeInt;
      VMTSize: SizeInt;
      Data: record end;

      function ClassType: TClass; inline;
      function VMT: PVmt; inline;
      function GetObject: TObject; inline;
    end;

    { TEnumerator }

    TEnumerator = record
    private
      Allocator: PBaseAllocator;
      CurrentData: PAllocMem;
      function GetCurrent: TObject;
    public
      property Current: TObject read GetCurrent;
      function MoveNext: Boolean;
    end;

  private
    class function AllocStruct(Obj: TObject): PAllocMem; static; inline;
    class procedure Extract(AllocMem: PAllocMem); static;
    class procedure CustomFreeInstance(Obj: TObject); static;
  private
    FFirstAlloc: PAllocMem;
    FLastAlloc: PAllocMem;
    FGetMem: TGetMemMethod;
    FFreeMem: TFreeMemMethod;
  public
    function VMTSize(VMTPtr: Pointer): SizeInt; inline;
    function InitClass(AllocMem: PAllocMem; AVMTSize: SizeInt; cls: TClass
      ): TObject;

    function Allocate(cls: TClass): TObject;
    function GetEnumerator: TEnumerator;
  public
    class operator Initialize(var Allocator: TBaseAllocator);
    class operator Finalize(var Allocator: TBaseAllocator);
    class operator AddRef(var Allocator: TBaseAllocator);
    class operator Copy(constref Source: TBaseAllocator; var Dest: TBaseAllocator);
  end;

  { THeapAllocator }

  THeapAllocator = record
  private
    FBase: TBaseAllocator;
    function GetMem(ASize: SizeInt): Pointer;
    procedure FreeMem(P: Pointer);
  public
    function GetEnumerator: TBaseAllocator.TEnumerator; inline;
    generic function Alloc<T>: T; inline;

    class operator Initialize(var HeapAlloc: THeapAllocator);
  end;

  { TStackAllocator }

  TStackAllocator = record
  private
    FBase: TBaseAllocator;
    function GetMem(ASize: SizeInt): Pointer;
    procedure FreeMem(P: Pointer);
  public
    function GetEnumerator: TBaseAllocator.TEnumerator; inline;
    generic function Alloc<T>: T; inline;

    class operator Initialize(var StackAlloc: TStackAllocator);
  end;

implementation

{ TBaseAllocator }

function TBaseAllocator.TAllocMem.ClassType: TClass;
begin
  Result := TClass(Pointer(@Data) + InstanceSize);
end;

function TBaseAllocator.TAllocMem.VMT: PVmt;
begin
  Result := PVMT(Pointer(@Data) + InstanceSize);
end;

function TBaseAllocator.TAllocMem.GetObject: TObject;
begin
  Result := TObject(@Data);
end;

function TBaseAllocator.TEnumerator.GetCurrent: TObject;
begin
  Result := CurrentData^.GetObject;
end;

function TBaseAllocator.TEnumerator.MoveNext: Boolean;
begin
  if Assigned(CurrentData) then
    CurrentData := CurrentData^.NextAlloc
  else
    CurrentData := Allocator^.FFirstAlloc;
  Result := Assigned(CurrentData);
end;

class function TBaseAllocator.AllocStruct(Obj: TObject): PAllocMem;
begin
  Result := PAllocMem(Pointer(Obj) - SizeOf(TAllocMem));
end;

class procedure TBaseAllocator.Extract(AllocMem: PAllocMem);
begin
  // Remove from linked list
  if Assigned(AllocMem^.LastAlloc) then
    AllocMem^.LastAlloc^.NextAlloc := AllocMem^.NextAlloc;
  if Assigned(AllocMem^.NextAlloc) then
    AllocMem^.NextAlloc^.LastAlloc := AllocMem^.LastAlloc;
  // Adjust first and last pointer in allocator
  if Assigned(AllocMem^.Allocator) then
  begin
    if AllocMem^.Allocator^.FFirstAlloc = AllocMem then
      AllocMem^.Allocator^.FFirstAlloc := AllocMem^.NextAlloc;
    if AllocMem^.Allocator^.FLastAlloc = AllocMem then
      AllocMem^.Allocator^.FLastAlloc := AllocMem^.LastAlloc;
    AllocMem^.Allocator := nil;
  end;
end;

class procedure TBaseAllocator.CustomFreeInstance(Obj: TObject);
var
  AllocMem: PAllocMem;
begin
  AllocMem := AllocStruct(Obj);
  Extract(AllocMem);
  Obj.CleanupInstance;
  if Assigned(AllocMem^.FreeFunc) then
    AllocMem^.FreeFunc(AllocMem);
end;

function TBaseAllocator.VMTSize(VMTPtr: Pointer): SizeInt;
begin
  Result := SizeOf(TVmt);
  while Assigned(PPointer(VMTPtr + Result)^) do
    Inc(Result, SizeOf(Pointer));
  Inc(Result, SizeOf(Pointer));
end;

function TBaseAllocator.InitClass(AllocMem: PAllocMem; AVMTSize: SizeInt; cls: TClass): TObject;
begin
  // Create linked list
  if not Assigned(FFirstAlloc) then
    FFirstAlloc := AllocMem;
  AllocMem^.LastAlloc := FLastAlloc;
  FLastAlloc := AllocMem;
  AllocMem^.NextAlloc := nil;
  AllocMem^.Allocator := @Self;
  AllocMem^.FreeFunc := FFreeMem;
  AllocMem^.VMTSize := AVMTSize;
  AllocMem^.InstanceSize := cls.InstanceSize;
  // Create class instance
  Result := cls.InitInstance(AllocMem^.GetObject);
  // Override VMT
  Move(PVMT(cls)^, AllocMem^.VMT^, AVMTSize);
  PPVmt(Result)^ := AllocMem^.VMT;
  AllocMem^.VMT^.vFreeInstance := @CustomFreeInstance;
end;

function TBaseAllocator.Allocate(cls: TClass): TObject;
var
  AllocMem: PAllocMem;
  AVMTSize: SizeInt;
begin
  Result := nil;
  if not Assigned(FGetMem) then
    Exit;
  AVMTSize := VMTSize(cls);
  AllocMem := FGetMem(SizeOf(TAllocMem) + AVMTSize + cls.InstanceSize);
  if not Assigned(AllocMem) then
    Exit;
  Result := InitClass(AllocMem, AVMTSize, cls);
end;

function TBaseAllocator.GetEnumerator: TEnumerator;
begin
  Result.Allocator := @Self;
  Result.CurrentData := Nil;
end;

class operator TBaseAllocator.Initialize(var Allocator: TBaseAllocator);
begin
  Allocator.FFirstAlloc := nil;
  Allocator.FLastAlloc := nil;
end;

class operator TBaseAllocator.Finalize(var Allocator: TBaseAllocator);
var
  Obj: TObject;
begin
  for Obj in Allocator do
    Obj.Free;
end;

class operator TBaseAllocator.AddRef(var Allocator: TBaseAllocator);
begin
  raise EUncopyable.Create('Allocators are not copyable');
end;

class operator TBaseAllocator.Copy(constref Source: TBaseAllocator;
  var Dest: TBaseAllocator);
begin
  raise EUncopyable.Create('Allocators are not copyable');
end;

{ THeapAllocator }

function THeapAllocator.GetMem(ASize: SizeInt): Pointer;
begin
  Result := System.Getmem(ASize);
end;

procedure THeapAllocator.FreeMem(P: Pointer);
begin
  System.Freemem(p);
end;

function THeapAllocator.GetEnumerator: TBaseAllocator.TEnumerator;
begin
  Result := FBase.GetEnumerator;
end;

generic function THeapAllocator.Alloc<T>: T;
begin
  Result := T(FBase.Allocate(T));
end;

class operator THeapAllocator.Initialize(var HeapAlloc: THeapAllocator);
begin
  HeapAlloc.FBase.FGetMem := @HeapAlloc.GetMem;
  HeapAlloc.FBase.FFreeMem := @HeapAlloc.FreeMem;
end;

{ TStackAllocator }

function TStackAllocator.GetMem(ASize: SizeInt): Pointer;
label
  MoveLoop, MoveEnd;
begin
  if ASize <= 0 then
    Exit(nil);
  if ASize < 8 then
    ASize := 8;
  {$AsmMode intel}
  asm
    MOV R9, ASize
    // RAX := RSP - ASize
    MOV RAX, RSP
    SUB RAX, R9
    // Alignment: Target (RBX) = RAX - (RAX mod SizeOf(Pointer))
    MOV RBX, RAX
    MOV RDX, 0
    MOV R8, SizeOf(Pointer)
    DIV R8
    SUB RBX, RDX
    // Adjust size for alignment
    ADD R9, RDX
    // Size (R8) := PPointer(RBP)^ + 2*SizeOf(Pointer) - Start (RSP)
    MOV R8, [RBP]
    ADD R8, 2*SizeOf(Pointer)
    SUB R8, RSP
    // i := 0
    MOV RCX, 0
    // while i < Size
  MoveLoop:
    CMP RCX, R8
    JNL MoveEnd
    // Target[i] := Start[i]
    MOV RAX, [RSP+RCX]
    MOV [RBX+RCX], RAX
    // i += SizeOf(Pointer)
    ADD RCX, SizeOf(Pointer)
    // End While
    JMP MoveLoop
  MoveEnd:
    // RSP, RBP, PPointer(RBP)^ -= ASize
    SUB RSP,   R9
    SUB RBP,   R9
    SUB [RBP], R9
    // Result := PPointer(RBP)^ + 2*SizeOf(Pointer)
    MOV RAX, [RBP]
    ADD RAX, 2*SizeOf(Pointer)
    MOV Result, RAX
  end;
end;

procedure TStackAllocator.FreeMem(P: Pointer);
begin
  // Do Nothing
end;

function TStackAllocator.GetEnumerator: TBaseAllocator.TEnumerator;
begin
  Result := FBase.GetEnumerator;
end;

generic function TStackAllocator.Alloc<T>: T;
begin
  Result := T(FBase.Allocate(T));
end;

class operator TStackAllocator.Initialize(var StackAlloc: TStackAllocator);
begin
  StackAlloc.FBase.FGetMem := @StackAlloc.GetMem;
  StackAlloc.FBase.FFreeMem := @StackAlloc.FreeMem;
end;

end.

