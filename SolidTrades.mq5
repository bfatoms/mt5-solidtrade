#property strict

string WebhookURL = "https://solidtrade.ticketbux.com/api/trades";
input string AccessToken = "";
input string accountID = "TEST_ACCOUNT";
input string SaveFileName = "last_deal.txt";
input bool EnableDebugLogs = false;                            // ✅ DISABLED BY DEFAULT
input bool ProcessHistoricalDeals = false;                    // ✅ OPTION TO SKIP HISTORICAL PROCESSING
input int MaxHistoricalDeals = 100;                          // ✅ LIMIT HISTORICAL PROCESSING

ulong lastProcessedDeal = 0;

//+------------------------------------------------------------------+
//| Debug print function                                             |
//+------------------------------------------------------------------+
void DebugPrint(string message)
{
   if (EnableDebugLogs)
   {
      Print("[DEBUG] ", message);
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== Enhanced Trade Sync EA Starting ===");
   
   // Only show essential info
   if (EnableDebugLogs)
   {
      Print("WebhookURL: " + WebhookURL);
      Print("AccountID: " + accountID);
      Print("ProcessHistoricalDeals: " + (ProcessHistoricalDeals ? "YES" : "NO"));
   }
   
   // Quick history selection - only recent period
   datetime fromTime = ProcessHistoricalDeals ? TimeCurrent() - (86400 * 7) : TimeCurrent(); // Last 7 days or current time
   if(!HistorySelect(fromTime, TimeCurrent()))
   {
      Print("❌ ERROR: Failed to select history!");
      return INIT_FAILED;
   }
   
   lastProcessedDeal = LoadLastProcessedDeal();
   DebugPrint("Loaded last processed deal ID: " + IntegerToString(lastProcessedDeal));

   // OPTIMIZED: Only process historical deals if explicitly enabled
   if (ProcessHistoricalDeals)
   {
      ProcessHistoricalDealsOptimized();
   }
   else
   {
      Print("⚡ Skipping historical deals processing for faster startup");
      Print("⚡ Only new trades will be synced from now on");
   }
   
   Print("=== Enhanced Trade Sync EA Ready ===");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OPTIMIZED: Process historical deals with limits                  |
//+------------------------------------------------------------------+
void ProcessHistoricalDealsOptimized()
{
   Print("Processing recent historical deals...");
   
   int total = HistoryDealsTotal();
   DebugPrint("Total historical deals found: " + IntegerToString(total));
   
   if(total == 0)
   {
      Print("No historical deals found");
      return;
   }
   
   // OPTIMIZATION 1: Limit how many deals to process
   int startIndex = MathMax(0, total - MaxHistoricalDeals);
   int processedCount = 0;
   
   // OPTIMIZATION 2: Process in forward order and break early when we hit processed deals
   for (int i = startIndex; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      
      // OPTIMIZATION 3: Skip if already processed
      if (ticket <= lastProcessedDeal)
      {
         continue;
      }

      // OPTIMIZATION 4: Batch select and validate deals
      if (!HistoryDealSelect(ticket))
      {
         continue;
      }

      // OPTIMIZATION 5: Quick type check before full processing
      int dealType = (int)HistoryDealGetInteger(ticket, DEAL_TYPE);
      int entry = (int)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      
      if (dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
         continue;
         
      if (entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_OUT)
         continue;

      // Process the deal with position tracking
      SendDealWithPositionTracking(ticket);
      lastProcessedDeal = ticket;
      processedCount++;
      
      // OPTIMIZATION 6: Prevent blocking the terminal
      if (processedCount % 10 == 0)
      {
         Sleep(1); // Small pause every 10 deals
      }
   }
   
   // Save only once at the end
   if (processedCount > 0)
   {
      SaveLastProcessedDeal(lastProcessedDeal);
      Print("Processed " + IntegerToString(processedCount) + " historical deals");
   }
}

//+------------------------------------------------------------------+
//| ENHANCED: Transaction handler with position tracking            |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
{
   // Process deal transactions (open/close)
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      
      // Skip if already processed
      if (dealTicket <= lastProcessedDeal)
         return;

      DebugPrint("New deal detected: " + IntegerToString(dealTicket));

      // Small delay only if needed
      if (!HistoryDealSelect(dealTicket))
      {
         Sleep(50);
         if (!HistoryDealSelect(dealTicket))
         {
            Print("❌ Failed to select deal: " + IntegerToString(dealTicket));
            return;
         }
      }

      // Quick validation
      int dealType = (int)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      int entry = (int)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      
      if (dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
         return;
         
      if (entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_OUT)
         return;

      SendDealWithPositionTracking(dealTicket);
      lastProcessedDeal = dealTicket;
      SaveLastProcessedDeal(lastProcessedDeal);
   }
   
   // NEW: Process position modifications (SL/TP changes)
   else if (trans.type == TRADE_TRANSACTION_POSITION)
   {
      DebugPrint("Position modification detected: " + IntegerToString(trans.position));
      SendPositionUpdate(trans.position);
   }
   
   // NEW: Process order modifications (pending orders, SL/TP changes via orders)
   else if (trans.type == TRADE_TRANSACTION_ORDER_UPDATE)
   {
      DebugPrint("Order modification detected: " + IntegerToString(trans.order));
      // Only process if it's related to an existing position
      ProcessOrderUpdate(trans.order);
   }
}

//+------------------------------------------------------------------+
//| ENHANCED: Send deal with position ID tracking                   |
//+------------------------------------------------------------------+
void SendDealWithPositionTracking(ulong dealTicket)
{
   // Extract deal information
   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double price = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   datetime time = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
   int dealType = (int)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   int entry = (int)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   ulong positionID = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   
   int type = (dealType == DEAL_TYPE_BUY) ? 0 : 1;
   string action = "";
   string timeField = "";
   
   // Determine action and time field based on entry type
   if (entry == DEAL_ENTRY_IN)
   {
      action = "position_open";
      timeField = "opened_at";
   }
   else if (entry == DEAL_ENTRY_OUT)
   {
      action = "position_close";
      timeField = "closed_at";
   }
   
   // Build JSON with position ID as the main identifier and access token
   string json = StringFormat(
      "{\"account_id\":\"%s\",\"access_token\":\"%s\",\"id\":%d,\"symbol\":\"%s\",\"type\":%d,\"volume\":%.2f,\"price\":%.5f,\"profit\":%.2f,\"%s\":%d,\"action\":\"%s\",\"deal_ticket\":%d}",
      accountID, AccessToken, positionID, symbol, type, volume, price, profit, timeField, (int)time, action, dealTicket
   );
   
   DebugPrint("Sending deal: " + json);
   SendTradeToWebhookOptimized(json);
}

//+------------------------------------------------------------------+
//| NEW: Send position update (SL/TP modifications)                 |
//+------------------------------------------------------------------+
void SendPositionUpdate(ulong positionTicket)
{
   if (!PositionSelectByTicket(positionTicket))
   {
      DebugPrint("Failed to select position: " + IntegerToString(positionTicket));
      return;
   }
      
   string symbol = PositionGetString(POSITION_SYMBOL);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double profit = PositionGetDouble(POSITION_PROFIT);
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   int type = (int)PositionGetInteger(POSITION_TYPE);
   ulong positionID = PositionGetInteger(POSITION_IDENTIFIER);
   
   // Build JSON for position update with access token
   string json = StringFormat(
      "{\"account_id\":\"%s\",\"access_token\":\"%s\",\"id\":%d,\"symbol\":\"%s\",\"type\":%d,\"volume\":%.2f,\"price\":%.5f,\"current_price\":%.5f,\"sl\":%.5f,\"tp\":%.5f,\"profit\":%.2f,\"opened_at\":%d,\"action\":\"position_update\",\"updated_at\":%d}",
      accountID, AccessToken, positionID, symbol, type, volume, openPrice, currentPrice, sl, tp, profit, (int)openTime, (int)TimeCurrent()
   );
   
   DebugPrint("Sending position update: " + json);
   SendTradeToWebhookOptimized(json);
}

//+------------------------------------------------------------------+
//| NEW: Process order updates that might affect positions          |
//+------------------------------------------------------------------+
void ProcessOrderUpdate(ulong orderTicket)
{
   // In MT5, SL/TP modifications are handled differently
   // They are typically processed through TRADE_TRANSACTION_POSITION
   // This function is kept for future extensibility
   
   DebugPrint("Order update detected: " + IntegerToString(orderTicket));
   
   // For now, we don't need to process individual order updates
   // since position modifications are caught by TRADE_TRANSACTION_POSITION
   // This could be extended later for pending orders or other order types
}

//+------------------------------------------------------------------+
//| OPTIMIZED: Webhook sender                                        |
//+------------------------------------------------------------------+
void SendTradeToWebhookOptimized(string payload)
{
   // Pre-allocate arrays
   uchar post[];
   int payloadLen = StringLen(payload);
   ArrayResize(post, payloadLen);
   StringToCharArray(payload, post, 0, payloadLen);

   uchar result[];
   string responseHeaders = "";
   
   // Minimal headers
   string headers = "Content-Type: application/json\r\n";

   ResetLastError();

   // Reduced timeout for faster failure detection
   int httpStatus = WebRequest(
      "POST",
      WebhookURL,
      headers,
      3000,                // Reduced timeout
      post,
      result,
      responseHeaders
   );

   if (httpStatus == -1)
   {
      int error = GetLastError();
      Print("❌ WebRequest failed. Error: " + IntegerToString(error));
      
      // Only show critical errors
      if (error == 4014)
      {
         Print("❌ Add webhook URL to MT5 WebRequest permissions");
      }
   }
   else
   {
      if (EnableDebugLogs || httpStatus != 200)
      {
         string response = CharArrayToString(result);
         Print("✅ HTTP " + IntegerToString(httpStatus) + ": " + response);
      }
   }
}

//+------------------------------------------------------------------+
//| OPTIMIZED: File operations                                       |
//+------------------------------------------------------------------+
void SaveLastProcessedDeal(ulong dealID)
{
   int h = FileOpen(SaveFileName, FILE_WRITE | FILE_BIN);
   if (h != INVALID_HANDLE)
   {
      FileWriteLong(h, dealID);
      FileClose(h);
      DebugPrint("Saved deal ID: " + IntegerToString(dealID));
   }
   else
   {
      Print("❌ Failed to save deal ID. Error: " + IntegerToString(GetLastError()));
   }
}

//+------------------------------------------------------------------+
//| OPTIMIZED: File loading                                          |
//+------------------------------------------------------------------+
ulong LoadLastProcessedDeal()
{
   int h = FileOpen(SaveFileName, FILE_READ | FILE_BIN);
   if (h != INVALID_HANDLE)
   {
      ulong id = FileReadLong(h);
      FileClose(h);
      return id;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Clean shutdown                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("=== Enhanced Trade Sync EA Stopped ===");
}