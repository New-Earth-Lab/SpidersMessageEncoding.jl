module SpidersMessageSerDes

using SimpleBinaryEncoding
evalschema(SpidersMessageSerDes, "./sbe-schemas/image.xml")
evalschema(SpidersMessageSerDes, "./sbe-schemas/dmcommand.xml")

end;