module SpidersMessageEncoding

using SimpleBinaryEncoding
evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/image.xml"))
evalschema(SpidersMessageEncoding, joinpath(@__DIR__, "../sbe-schemas/dmcommand.xml"))

const MessageHeader = messageHeader
export MessageHeader
export Image
export DmCommand

end;