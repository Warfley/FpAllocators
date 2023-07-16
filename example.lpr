program project1;

{$mode Delphi}

uses
  Classes, allocators;

procedure Smack;
var
  arr: array[0..1023] of Byte;
begin
  FillChar(arr, SizeOf(arr), $FF);
end;

procedure TestStack;
var
  alloc: TStackAllocator;
  sl: TStrings;
begin
  sl := alloc.Alloc<TStringList>.Create;
  sl.Add('Foo');
  Smack;
  sl.Add('Bar');
  WriteLn(sl.Text);
end; 

procedure TestHeap;
var
  alloc: THeapAllocator;
  sl: TStrings;
begin
  sl := alloc.Alloc<TStringList>.Create;
  sl.Add('Foo');
  Smack;
  sl.Add('Bar');
  WriteLn(sl.Text);
end;

begin
  TestStack;
  TestHeap;
  ReadLn;
end.
