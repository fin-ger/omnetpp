//==========================================================================
//   CEXPRESSION.CC  - part of
//                     OMNeT++/OMNEST
//            Discrete System Simulation in C++
//
//  Author: Andras Varga
//
//==========================================================================

/*--------------------------------------------------------------*
  Copyright (C) 1992-2017 Andras Varga
  Copyright (C) 2006-2017 OpenSim Ltd.

  This file is distributed WITHOUT ANY WARRANTY. See the file
  `license' for details on this and other legal matters.
*--------------------------------------------------------------*/

#include "omnetpp/cexpression.h"

using namespace std;

namespace omnetpp {

cNedValue cExpression::evaluate(cComponent *contextComponent) const
{
    Context context(contextComponent);
    return evaluate(&context);
}

bool cExpression::boolValue(cComponent *contextComponent)
{
    Context context(contextComponent);
    return boolValue(&context);
}

intpar_t cExpression::intValue(cComponent *contextComponent, const char *expectedUnit)
{
    Context context(contextComponent);
    return intValue(&context);
}

double cExpression::doubleValue(cComponent *contextComponent, const char *expectedUnit)
{
    Context context(contextComponent);
    return doubleValue(&context);
}

std::string cExpression::stringValue(cComponent *contextComponent)
{
    Context context(contextComponent);
    return stringValue(&context);
}

cXMLElement *cExpression::xmlValue(cComponent *contextComponent)
{
    Context context(contextComponent);
    return xmlValue(&context);
}

}  // namespace omnetpp

