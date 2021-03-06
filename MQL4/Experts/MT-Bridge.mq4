//+------------------------------------------------------------------+
//|                                      metatrader-data-capture.mq4 |
//|                        Copyright 2019, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+

#property copyright "Copyright 2019, Yaroslav Barabanov."
#property link      "https://www.mql5.com"
#property description "MT-BRIDGE sends the data stream through the socket to the local server." 
#property description "MT-BRIDGE is the bridge between Metatrader and your program." 
#property version   "1.00"
#property icon "\\Images\\mt-bridge-v1.ico";
#property strict

#include "..\Include\socket-library-mt4-mt5.mqh"

const uint MT_BRIDGE_VERSION = 1; // версия MT-BRIDGE

#import "msvcrt.dll"
  int memset(uchar &dst[],  uchar src, int cnt); 
  int memset(char &dst[],  char src, int cnt); 
  int memcpy(uchar &dst[],  double &src, int cnt);
  int memcpy(uchar &dst[],  const double &src, int cnt);
  int memcpy(uchar &dst[],  long &src, int cnt);
  int memcpy(uchar &dst[],  uint &src, int cnt);
  int memcpy(uchar &dst[],  const uint &src, int cnt);
  int memcpy(uchar &dst[],  MqlRates &candles[], int cnt);
  int memcpy(uchar &dst[],  datetime &time, int cnt);
  int memcpy(uchar &dst[],  string &str, int cnt);
  int memcpy(char &dst[],  string &str, int cnt);
  int memcpy(int, int, int);
#import

static string symbol_name[];

input string   Hostname = "localhost"; // Server hostname or IP address
input ushort   ServerPort = 5555;      // Server port
input string   UserSymbolsList = 
         "EURUSD,USDJPY,GBPUSD,USDCHF,USDCAD,EURJPY,AUDUSD,NZDUSD,"
         "EURGBP,EURCHF,AUDJPY,GBPJPY,CHFJPY,EURCAD,AUDCAD,CADJPY,"
         "NZDJPY,AUDNZD,GBPAUD,EURAUD,GBPCHF,EURNZD,AUDCHF,GBPNZD,"
         "GBPCAD,XAUUSD";              // Array of used currency pairs
input ushort UpdateMillisecond = 1000; // Data update period (milliseconds)
input ushort DepthHistory = 1440;      // Depth of history to initialize
         
static ClientSocket * glbClientSocket = NULL;
static uint num_symbol = 0;         // количество символов
static uchar byte_arr[32];          // массив битов для буфера сокета
static MqlRates rates_data[];       // массив котировок
static MqlTick symbol_tick;         // инфорация о тике
static datetime last_timestamp = 0;
static bool is_print_sh_status[];

ulong get_symbols(string &SymbolsList[]);

int OnInit() {
   EventSetMillisecondTimer(UpdateMillisecond);
   
   string real_symbols[];
   ulong num_real_symbol = get_symbols(real_symbols);
   if(num_real_symbol == 0) return(INIT_FAILED);
   
   /* парсим массив валютных пар */
   string sep=",";
   ushort u_sep;
   u_sep=StringGetCharacter(sep,0);
   int k = StringSplit(UserSymbolsList, u_sep, symbol_name);
   num_symbol = ArraySize(symbol_name);
   
   for(uint s = 0; s < num_symbol; ++s) {
      bool is_found = false;
      for(uint rs = 0; rs < num_real_symbol; ++rs) {
         if(real_symbols[rs] == symbol_name[s]) {
            is_found = true;
            break;
         }
      }
      if(is_found) {
         Print(symbol_name[s], " symbol added, index: ", s);
      } else {
         Print("Error! ",symbol_name[s]," symbol not found!");
         return(INIT_FAILED);
      }
   }

   ArraySetAsSeries(rates_data,true);
   
   ArrayResize(is_print_sh_status, num_symbol);
   ArrayInitialize(is_print_sh_status, false);
   /* запоминаем мтеку времени начала работы */
   last_timestamp = TimeCurrent();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   delete glbClientSocket;
   glbClientSocket = NULL;
   EventKillTimer();
}

/* получаем строку */
void string_to_bytes(uchar &bytes[], string &str, uint len) {
   uint copy_bytes = MathMin(len, StringLen(str));
   StringToCharArray(str, bytes, 0, copy_bytes);
}

/* отправляем данные */
void send_data(int start_pos = 0) {
   RefreshRates(); // Далее гарантируется, что все данные обновлены
   for(uint s = 0; s < num_symbol; ++s) {
      int err = CopyRates(symbol_name[s], PERIOD_M1, start_pos, 1, rates_data);
      if(err > 0 && SymbolInfoTick(symbol_name[s],symbol_tick)) {
         /* передаем данные через сокет */
         
         /* сначала передаем bid и ask */
         memcpy(byte_arr, symbol_tick.bid, sizeof(symbol_tick.bid));
         glbClientSocket.SendRaw(byte_arr, sizeof(symbol_tick.bid));
         memcpy(byte_arr, symbol_tick.ask, sizeof(symbol_tick.ask));
         glbClientSocket.SendRaw(byte_arr, sizeof(symbol_tick.ask));
         
         /* передаем цены бара */
         memcpy(byte_arr, rates_data[0].open, sizeof(rates_data[0].open));
         glbClientSocket.SendRaw(byte_arr, sizeof(rates_data[0].open));
         memcpy(byte_arr, rates_data[0].high, sizeof(rates_data[0].high));
         glbClientSocket.SendRaw(byte_arr, sizeof(rates_data[0].high));
         memcpy(byte_arr, rates_data[0].low, sizeof(rates_data[0].low));
         glbClientSocket.SendRaw(byte_arr, sizeof(rates_data[0].low));
         memcpy(byte_arr, rates_data[0].close, sizeof(rates_data[0].close));
         glbClientSocket.SendRaw(byte_arr, sizeof(rates_data[0].close));
         
         /* передаем объем */
         memcpy(byte_arr, rates_data[0].tick_volume, sizeof(rates_data[0].tick_volume));
         glbClientSocket.SendRaw(byte_arr, sizeof(rates_data[0].tick_volume));
         
         /* передаем метку времени */
         memcpy(byte_arr, rates_data[0].time, sizeof(rates_data[0].time));
         glbClientSocket.SendRaw(byte_arr, sizeof(rates_data[0].time));
         if(is_print_sh_status[s]) {
            Print(symbol_name[s]," historical data uploaded successfully");
            is_print_sh_status[s] = false;
         }
      } else {
      
         /* отправляем пустые данные */
         const double NULL_DATA = 0.0;
         for(uint i = 0; i < 7; ++i) {
            memcpy(byte_arr, NULL_DATA, sizeof(NULL_DATA));
            glbClientSocket.SendRaw(byte_arr, sizeof(NULL_DATA));
         }
         /* передаем метку времени */
         datetime server_time = TimeCurrent();
         memcpy(byte_arr, server_time, sizeof(datetime));
         glbClientSocket.SendRaw(byte_arr, sizeof(datetime));
         if(!is_print_sh_status[s]) {
            Print("Failed to get history data for the symbol ",symbol_name[s]);
            is_print_sh_status[s] = true;
         }
      }
   } // for s
   
   /* отправляем время сервера */
   datetime server_time = TimeCurrent();
   memcpy(byte_arr, server_time, sizeof(datetime));
   glbClientSocket.SendRaw(byte_arr, sizeof(datetime));
}


void update() {
   /* сначала запустим сокет */
   static bool is_print_status = false;
   if(!glbClientSocket) {
      glbClientSocket = new ClientSocket(Hostname, ServerPort);
      if(glbClientSocket.IsSocketConnected()) {
         Print("MT-BRIDGE connection succeeded!");
         is_print_status = false;
         /* отправим версию */
         memcpy(byte_arr, MT_BRIDGE_VERSION, sizeof(MT_BRIDGE_VERSION));
         glbClientSocket.SendRaw(byte_arr, sizeof(MT_BRIDGE_VERSION)); 
         
         /* отправим количество символов */
         memcpy(byte_arr, num_symbol, sizeof(num_symbol));
         glbClientSocket.SendRaw(byte_arr, sizeof(num_symbol)); 
         
         /* отправим имена валютных пар по порядку */
         for(uint i = 0; i < num_symbol; ++i) {
            memset(byte_arr,0, 32);
            string_to_bytes(byte_arr, symbol_name[i], 32);
            glbClientSocket.SendRaw(byte_arr, 32);
         }
         
         /* отправим иторические данные */
         const uint hist_len = DepthHistory;  
         memcpy(byte_arr, hist_len, sizeof(hist_len));
         glbClientSocket.SendRaw(byte_arr, sizeof(hist_len)); 
         if(DepthHistory > 0) {
            EventKillTimer();
            for(uint h = DepthHistory; h > 0; --h) {
               send_data(h);
            } 
            EventSetMillisecondTimer(UpdateMillisecond);
         }
         
         /* а дальше ничего =) */
      } else {
         delete glbClientSocket;
         glbClientSocket = NULL;
         if(!is_print_status) Print("MT-BRIDGE connection failed! Wait...");
         is_print_status = true;
         return;
      }
   }
   
   if(!glbClientSocket.IsSocketConnected()) {
      Print("MT-BRIDGE disconnected!");
      delete glbClientSocket;
      glbClientSocket = NULL;
      return;
   }
   
   /* обновим котировки */
   datetime server_time = TimeCurrent();
   if((server_time/60) != (last_timestamp/60)) {
      last_timestamp = server_time;
      send_data(1);
   }
   send_data(0);
}

void OnTick() {
   
}

void OnTimer() {
   update();
}

/* получаем список символов */
ulong get_symbols(string &SymbolsList[]) {
   // Открываем файл  symbols.raw
   int hFile = FileOpenHistory("symbols.raw", FILE_BIN|FILE_READ);
   if(hFile < 0) return(-1);
   // Определяем количество символов, зарегистрированных в файле
   ulong SymbolsNumber = FileSize(hFile) / 1936;
   ArrayResize(SymbolsList, (int)SymbolsNumber);
   // Считываем символы из файла
   for(ulong i = 0; i < SymbolsNumber; ++i) {
      SymbolsList[(int)i] = FileReadString(hFile, 12);
      FileSeek(hFile, 1924, SEEK_CUR);
   }
   // Возвращаем общее количество инструментов
   return(SymbolsNumber);
}