{-# LANGUAGE OverloadedStrings #-}
module Chip8.CPU where

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.State
import Data.Bits
import qualified Data.ByteString as BS
import Data.Vector.Unboxed ((!), (//), Vector, replicate)
import Data.Word
import Numeric
import Prelude hiding (replicate)

data CPUState = CPUState
  { memory :: Vector Word8
  , vRegs :: Vector Word8
  , iReg :: Address
  , pc :: Address
  , sp :: Word8
  } deriving (Eq, Read, Show)

type CPU = StateT CPUState IO
type Address = Word16
type Instruction = Word16
type Register = Int --index of vector

testAction = replicateM_ 100 $ do
  cpu <- get
  let cpc = showHex (pc cpu) ""
  cmd <- fetch
  liftIO . putStr $ cpc ++ "> " ++ showHex cmd " : "
  interpret cmd
  --liftIO . putStrLn $ "done."
  return ()

initCPU :: CPUState
initCPU = CPUState
  { memory = replicate (4 * 1024) 0x0
  , vRegs = replicate 16 0x0
  , iReg = 0x0
  , pc = initPC
  , sp = 0x0
  }

initPC :: Address
initPC = 0x200

runCPU :: CPU ()
runCPU = do
  liftIO $ putStrLn "running cpu"
  fetch >>= interpret
  return ()

loadProgram :: FilePath -> CPU ()
loadProgram f = do
  program <- liftIO $ loadFile f
  let mem = memory initCPU
  put $ initCPU {memory = mem // program}
  return ()
    where loadFile f = do
            contents <- liftM BS.unpack $ BS.readFile f
            return $ zip addresses contents
              where addresses = [fromIntegral initPC..]::[Int]

tempLoadFile f = do
  contents <- liftM BS.unpack $ BS.readFile f
  return $ zip addresses contents
    where addresses = [fromIntegral initPC..]::[Int]

printProgram ((addr, upper):(_,lower):xs) = do
  putStrLn $ showHex addr "" ++ "> " ++ showHex (mergeWord8 upper lower) ""
  printProgram xs
printProgram _ = return ()

fetch :: CPU Instruction
fetch = do
  mem <- getMem
  pc <- getPC
  let index = fromIntegral pc::Int
  return $ mergeWord8 (mem ! index) (mem ! (index + 1))

interpret :: Instruction -> CPU ()
interpret inst = do
  let msb = (inst .&. 0xF000) `shiftR` 12
      lsb = inst .&. 0xF
      x = fromIntegral $ (inst .&. 0x0F00) `shiftR` 8
      y = fromIntegral $ (inst .&. 0x00F0) `shiftR` 4
      kk = fromIntegral $ inst .&. 0xFF
      nnn = inst .&. 0xFFF
  cpu <- get
  mem <- getMem
  regs <- getVRegs
  i <- getI
  stackPointer <- liftM fromIntegral getSP
  programCounter <- getPC
  vx <- getRegValue $ fromIntegral x
  vy <- getRegValue $ fromIntegral y
  case msb of
    0x0 ->
      case kk of
        -- |00E0 - CLS
        -- Clear the display
        0xE0 -> do
          liftIO . putStrLn $ "CLS not implemented."
          return ()
        -- |00EE - RET
        -- Return from a subroutine
        0xEE -> do
          liftIO . putStrLn $ "RET"
          setPC stackPointer
          decSP
        _ -> liftIO . putStrLn $ "invalid instruction" ++ showHex inst ""
    -- |1nnn - JP addr
    -- Jump to location nnn
    0x1 -> do
      liftIO . putStrLn $ "JP " ++ showHex nnn ""
      setPC nnn
    -- |2nnn - CALL addr
    -- Call subroutine at nnn
    0x2 -> do
      liftIO . putStrLn $ "CALL " ++ showHex nnn ""
      incSP
      pushStack programCounter
      setPC nnn
    -- |3xkk - SE Vx, byte
    -- Skip next instruction if Vx = kk.
    0x3 -> do
      liftIO . putStrLn $ "SE " ++ showHex vx ", " ++ showHex kk ""
      incPC >> when (vx == kk) incPC
    -- |4xkk - SNE Vx, byte
    -- Skip next instruction if Vx != kk.
    0x4 -> do
      liftIO . putStrLn $ "SNE " ++ showHex vx ", " ++ showHex kk ""
      incPC >> when (vx /= kk) incPC
    -- |5xy0 - SE Vx, Vy
    -- Skip next instruction if Vx = Vy
    0x5 ->
      case lsb of
        0 -> incPC >> when (vx == vy) incPC
        _ -> liftIO . putStrLn $ "invalid instruction " ++ showHex inst ""
    -- |6xkk - LD Vx, byte
    -- Set Vx = kk
    0x6 -> do
      liftIO . putStrLn $ "LD V" ++ showHex x ", " ++ showHex kk ""
      setReg x kk >> incPC
    -- |7xkk - ADD Vx, byte
    -- Set Vx = Vx + kk.
    0x7 -> do
      liftIO . putStrLn $ "ADD V" ++ showHex x ", " ++ showHex kk ""
      modifyReg x (kk +) >> incPC
    0x8 ->
      case lsb of
        -- |8xy0 - LD Vx, Vy
        -- Stores the value of register Vy in register Vx
        0 -> do
          liftIO . putStrLn $ "LD V" ++ showHex x ", V" ++ showHex y ""
          setReg x vy >> incPC
        -- |8xy1 - OR Vx, Vy
        -- Set Vx = Vx OR Vy
        1 -> do
          liftIO . putStrLn $ "OR V" ++ showHex x ", V" ++ showHex y ""
          setReg x (vx .|. vy) >> incPC
        _ -> error $ "inv inst " ++ showHex inst ""
    -- |Annn - LD I, addr
    -- Set I = nnn.
    0xA -> do
      liftIO . putStrLn $ "LD I, " ++ showHex nnn ""
      setI nnn >> incPC
    -- |Dxyn - DRW Vx, Vy, nibble
    -- Display n-byte sprite starting at memory location I at
    -- (Vx, Vy), set VF = collision.
    0xD -> do
      liftIO . putStrLn $ "drawing is not implemented."
      incPC
    0xF ->
      case kk of
        -- |Fx33 - LD B, Vx
        -- Store BCD representation of Vx in memory locations
        -- I, I+1, and I+2.
        0x33 -> do
          liftIO . putStrLn $ "LD B, V" ++ showHex x ""
          let bcd = toBCD vx
              memoryUpdate = zip [i..] bcd
          mapM_ (uncurry writeWord8) memoryUpdate
          incPC
        -- |Fx55 - LD [I], Vx
        -- Store registers V0 through Vx in memory starting
        -- at location I.
        0x55 -> do
          liftIO . putStrLn $ "LD [I], V" ++ showHex x ""
          let loc = map fromIntegral [i..]
          vals <- mapM getRegValue [0..15]
          let memUpdate = zip loc vals
          put $ cpu {memory = mem // memUpdate}
          incPC
        -- |Fx65 - LD Vx, [I]
        -- Read registers V0 through Vx from memory starting
        -- at location I.
        0x65 -> do
          liftIO . putStrLn $ "LD V" ++ showHex x ", [I]"
          let loc = [i..]
          vals <- mapM readWord8 loc
          let vregsUpdate = zip [0..15] vals
          put $ cpu {vRegs = regs // vregsUpdate }
          incPC
        _ -> error $ "unimplemented " ++ showHex inst ""
    _ -> error $ "unable to interpret " ++ showHex inst ""
  return ()

toBCD :: Word8 -> [Word8]
toBCD n = map read chars
  where chars = map (:[]) (show n)

pushStack :: Address -> CPU ()
pushStack addr = do
  stackPointer <- getSP
  writeWord16 (fromIntegral stackPointer) addr
  return ()

popStack :: CPU ()
popStack = do
  liftIO . putStrLn $ "popStack not implemented."
  return ()

modifySP f = do
  cpu <- get
  put $ cpu {sp = f $ sp cpu}
  return ()

incSP = modifySP $ (+) 2
decSP = modifySP $ (-) 2

modifyPC :: (Address -> Address) -> CPU ()
modifyPC f = do
  cpu <- get
  put $ cpu {pc = f $ pc cpu}
  return ()

incPC = modifyPC $ (+) 2
decPC = modifyPC $ (-) 2
setPC addr = modifyPC (const addr)

getPC :: CPU Address
getPC = do
  cpu <- get
  return $ pc cpu

setI :: Address -> CPU ()
setI val = do
  cpu <- get
  put $ cpu {iReg = val}
  return ()

getI :: CPU Address
getI = do
  cpu <- get
  return $ iReg cpu

setReg :: Register -> Word8 -> CPU ()
setReg reg val = modifyReg reg $ const val

modifyReg :: Register -> (Word8 -> Word8) -> CPU ()
modifyReg reg f = do
  cpu <- get
  regs <- getVRegs
  currentValue <- getRegValue reg
  let newVal = f currentValue
  put cpu {vRegs = regs // [(reg, newVal)]}
  return ()

getRegValue :: Register -> CPU Word8
getRegValue reg = do
  regs <- getVRegs
  return $ regs ! reg

getVRegs :: CPU (Vector Word8)
getVRegs = do
  cpu <- get
  return $ vRegs cpu

getMem :: CPU (Vector Word8)
getMem = do
  cpu <- get
  return $ memory cpu

getSP :: CPU Word8
getSP = do
  cpu <- get
  return $ sp cpu

readWord8 :: Address -> CPU Word8
readWord8 addr = do
  mem <- getMem
  return $ mem ! fromIntegral addr

writeWord8 :: Address -> Word8 -> CPU ()
writeWord8 addr val = do
  cpu <- get
  mem <- getMem
  let index = fromIntegral addr
  put $ cpu {memory = mem // [(index, val)]}
  return ()

--Writes a Word16 at an address in to two Word8's
writeWord16 :: Address -> Word16 -> CPU ()
writeWord16 addr val = do
  cpu <- get
  mem <- getMem
  let index = fromIntegral addr
      (upper, lower) = splitWord16 val
      modifiedMemory = mem // [(index, upper), (index + 1, lower)]
  put $ cpu {memory = modifiedMemory}
  return ()

splitWord16 :: Word16 -> (Word8, Word8)
splitWord16 w = mapTuple fromIntegral ((w .&. 0xFF00) `shiftR` 8, w .&. 0xFF)
  where mapTuple f (a, b) = (f a, f b)

mergeWord8 :: Word8 -> Word8 -> Word16
mergeWord8 a b = upper `shiftL` 8  .|. lower
  where upper = fromIntegral a
        lower = fromIntegral b

